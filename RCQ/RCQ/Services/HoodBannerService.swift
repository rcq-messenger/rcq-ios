import Combine
import Foundation

@MainActor
final class HoodBannerService: ObservableObject {
    static let shared = HoodBannerService()

    @Published private(set) var bannersByBucket: [String: [HoodBanner]] = [:]
    @Published private(set) var canPostByBucket: [String: Bool] = [:]
    @Published private(set) var cooldownByBucket: [String: Int] = [:]
    @Published var lastError: String?

    private init() {}

    func banners(for bucket: String) -> [HoodBanner] {
        bannersByBucket[bucket] ?? []
    }

    func refresh(bucket: String) async {
        do {
            let out: HoodBannerList = try await APIClient.shared.request(
                "GET", "/hood/banners/\(bucket)"
            )
            bannersByBucket[bucket] = out.items
            canPostByBucket[bucket] = out.canPost
            cooldownByBucket[bucket] = out.cooldownRemainingSeconds
        } catch {
            print("[HoodBannerService] refresh failed: \(error)")
        }
    }

    enum CreateResult {
        case success(HoodBanner, walletTokens: Int)
        case insufficientTokens(required: Int, have: Int)
        case bucketFull
        case alreadyHaveBanner
        case cooldown(seconds: Int)
        case other(String)
    }

    func create(
        bucket: String,
        text: String,
        duration: BannerDuration,
        isAnonymous: Bool,
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
        }
        struct Out: Decodable {
            let banner: HoodBanner
            let walletTokens: Int
            enum CodingKeys: String, CodingKey {
                case banner
                case walletTokens = "wallet_tokens"
            }
        }
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
                )
            )
            // Optimistic local insert.
            var list = bannersByBucket[bucket] ?? []
            list.insert(out.banner, at: 0)
            bannersByBucket[bucket] = list
            ItemsService.shared.setWalletTokens(out.walletTokens)
            return .success(out.banner, walletTokens: out.walletTokens)
        } catch APIError.http(402, let body) {
            let (req, have) = Self.parseInsufficient(body)
            return .insufficientTokens(required: req, have: have)
        } catch APIError.http(409, let body) {
            let detail = (body ?? "").lowercased()
            if detail.contains("bucket full") { return .bucketFull }
            if detail.contains("already have") { return .alreadyHaveBanner }
            return .other(body ?? "conflict")
        } catch APIError.http(429, let body) {
            return .cooldown(seconds: Self.parseCooldown(body))
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
            lastError = error.localizedDescription
        }
    }

    func report(bannerID: Int) async {
        do {
            let _: EmptyResponse? = try await APIClient.shared.request(
                "POST", "/hood/banners/\(bannerID)/report"
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func parseInsufficient(_ body: String?) -> (Int, Int) {
        guard let body else { return (0, 0) }
        let nums = body.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return nums.count >= 2 ? (nums[0], nums[1]) : (0, 0)
    }

    private static func parseCooldown(_ body: String?) -> Int {
        guard let body else { return 0 }
        return body.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first ?? 0
    }
}
