import Combine
import Foundation

/// Per-bucket cache for district-banner placements. UI calls
/// `refresh(bucket:)` on appear and `create(...)` from the composer.
/// Pricing is fetched lazily on first composer open.
@MainActor
final class HoodBannerService: ObservableObject {
    static let shared = HoodBannerService()

    @Published private(set) var bannersByBucket: [String: [HoodBanner]] = [:]
    @Published private(set) var canPostByBucket: [String: Bool] = [:]
    @Published private(set) var pricing: [HoodBannerPricing] = []

    private init() {}

    func banners(for bucket: String) -> [HoodBanner] {
        bannersByBucket[bucket] ?? []
    }

    func canPost(in bucket: String) -> Bool {
        canPostByBucket[bucket] ?? true
    }

    /// Pull the bucket roster + refresh `canPost`. Soft-fail keeps
    /// the prior cached list.
    func refresh(bucket: String) async {
        do {
            let out: HoodBannerList = try await APIClient.shared.request(
                "GET", "/hood/banners/\(bucket)"
            )
            bannersByBucket[bucket] = out.items
            canPostByBucket[bucket] = out.canPost
        } catch {
            print("[HoodBannerService] refresh failed: \(error)")
        }
    }

    /// Fetch the IAP-tier table. Idempotent; only re-fetches if the
    /// cached list is empty.
    func fetchPricing() async {
        guard pricing.isEmpty else { return }
        do {
            let out: [HoodBannerPricing] = try await APIClient.shared.request(
                "GET", "/hood/banners/pricing"
            )
            pricing = out
        } catch {
            // Fallback to the per-enum constants if the network call
            // failed — UI never blocks on this.
        }
    }

    enum CreateResult {
        case success(HoodBanner)
        case bucketFull
        case other(String)
    }

    func create(
        bucket: String,
        text: String,
        duration: BannerDuration,
        isAnonymous: Bool,
        receipt: String,
        imageURL: String? = nil,
        imageThumbURL: String? = nil,
    ) async -> CreateResult {
        struct Body: Encodable {
            let bucket_id: String
            let text: String
            let duration: String
            let is_anonymous: Bool
            let image_url: String?
            let image_thumb_url: String?
            let receipt: String
        }
        struct Out: Decodable { let banner: HoodBanner }
        do {
            let out: Out = try await APIClient.shared.request(
                "POST", "/hood/banners",
                body: Body(
                    bucket_id: bucket,
                    text: text,
                    duration: duration.rawValue,
                    is_anonymous: isAnonymous,
                    image_url: imageURL,
                    image_thumb_url: imageThumbURL,
                    receipt: receipt,
                )
            )
            var list = bannersByBucket[bucket] ?? []
            list.insert(out.banner, at: 0)
            bannersByBucket[bucket] = list
            return .success(out.banner)
        } catch APIError.http(409, let body) {
            let detail = (body ?? "").lowercased()
            if detail.contains("bucket_full") { return .bucketFull }
            return .other(body ?? "conflict")
        } catch {
            return .other(error.localizedDescription)
        }
    }

    func delete(bannerID: Int, bucket: String) async {
        do {
            let _: EmptyResponse? = try await APIClient.shared.request(
                "DELETE", "/hood/banners/\(bannerID)"
            )
            bannersByBucket[bucket]?.removeAll { $0.id == bannerID }
        } catch {
            print("[HoodBannerService] delete failed: \(error)")
        }
    }
}
