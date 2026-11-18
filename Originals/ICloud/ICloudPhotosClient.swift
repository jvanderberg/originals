import Foundation
import Photos

/// One downloadable file in an iCloud Photos record.
struct ICloudFile: Sendable {
    let size: Int64
    let url: URL
    /// UTI, e.g. "com.apple.quicktime-movie", "public.mpeg-4", "public.jpeg".
    let fileType: String?

    var fileExtension: String {
        switch fileType {
        case "com.apple.quicktime-movie": "MOV"
        case "public.mpeg-4": "MP4"
        case "public.jpeg": "JPG"
        case "public.heic": "HEIC"
        case "public.png": "PNG"
        default: "DAT"
        }
    }
}

/// A CPLMaster record: the original files of one asset, plus the smaller versions iCloud made from them.
struct ICloudMaster: Sendable {
    let recordName: String
    let filename: String?
    /// Keyed by field prefix without the "Res" suffix, e.g. "resOriginal", "resVidLarge".
    let files: [String: ICloudFile]
}

/// The smaller versions iCloud keeps, best first. Measured on a 4K HDR video:
/// resVidLarge 1920×1080 HEVC (keeps HDR), resVidMed 1280×720 H.264, resVidSmall 640×360 H.264.
/// For photos, resJPEGMed is a JPEG about 2,400 px on the long side.
enum ICloudRendition {
    static func original(for type: PHAssetResourceType) -> String? {
        switch type {
        case .photo, .video, .audio: "resOriginal"
        case .alternatePhoto: "resOriginalAlt"
        case .pairedVideo: "resOriginalVidCompl"
        default: nil
        }
    }

    static let smallerVideo: [(field: String, label: String)] = [
        ("resVidLarge", "1080p"), ("resVidMed", "720p"), ("resVidSmall", "360p"),
    ]
    static let smallerPhoto: [(field: String, label: String)] = [("resJPEGMed", "medium")]
}

/// Talks to the iCloud Photos web database (what icloud.com and icloudpd use).
struct ICloudPhotosClient: Sendable {
    let account: ICloudAccount
    let session: URLSession

    /// The CPLMaster record name for a Photos asset. PhotoKit's cloud identifier ends with it:
    /// "53504665-…:001:AUv8LeGtBVnNAx0V6QWRRMmNgetD".
    static func masterRecordName(for asset: PHAsset) -> String? {
        let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: [asset.localIdentifier])
        guard case let .success(cloud)? = mappings[asset.localIdentifier] else { return nil }
        let name = cloud.stringValue.split(separator: ":").last.map(String.init)
        return name?.isEmpty == false ? name : nil
    }

    /// POST …/records/lookup for one or more CPLMaster records in the PrimarySync zone.
    func lookup(_ recordNames: [String]) async throws -> [String: ICloudMaster] {
        var components = URLComponents(url: account.databaseURL.appendingPathComponent(
            "database/1/com.apple.photos.cloud/production/private/records/lookup"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            // Same client parameters icloudpd sends.
            URLQueryItem(name: "clientBuildNumber", value: "2522Project44"),
            URLQueryItem(name: "clientMasteringNumber", value: "2522B2"),
            URLQueryItem(name: "clientId", value: Self.clientID),
            URLQueryItem(name: "dsid", value: account.dsid),
            URLQueryItem(name: "remapEnums", value: "true"),
            URLQueryItem(name: "getCurrentSyncToken", value: "true"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "records": recordNames.map { ["recordName": $0] },
            "zoneID": ["zoneName": "PrimarySync"],
        ])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ICloudError.http(status, "record lookup") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = json["records"] as? [[String: Any]] else {
            throw ICloudError.unexpectedResponse("record lookup")
        }
        var result: [String: ICloudMaster] = [:]
        for record in records {
            guard let name = record["recordName"] as? String,
                  let fields = record["fields"] as? [String: Any] else { continue }
            result[name] = Self.parseMaster(name: name, fields: fields)
        }
        return result
    }

    private static let clientID = UUID().uuidString.lowercased()

    private static func parseMaster(name: String, fields: [String: Any]) -> ICloudMaster {
        func value(_ key: String) -> Any? { (fields[key] as? [String: Any])?["value"] }
        let filename = (value("filenameEnc") as? String)
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        var files: [String: ICloudFile] = [:]
        for (key, _) in fields where key.hasSuffix("Res") {
            guard let res = value(key) as? [String: Any],
                  let template = res["downloadURL"] as? String,
                  let size = (res["size"] as? NSNumber)?.int64Value else { continue }
            let prefix = String(key.dropLast(3))
            // Download URLs end in a "${f}" placeholder for the file name, as on icloud.com.
            let fileName = (filename ?? "file").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "file"
            guard let url = URL(string: template.replacingOccurrences(of: "${f}", with: fileName)) else { continue }
            files[prefix] = ICloudFile(size: size, url: url, fileType: value("\(prefix)FileType") as? String)
        }
        return ICloudMaster(recordName: name, filename: filename, files: files)
    }
}
