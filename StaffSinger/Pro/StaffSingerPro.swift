//
//  StaffSingerPro.swift
//  StaffSinger
//
//  초견 Pro — 무료 · Pro 두 칸. **속은 전부 LeeoKit 의 `LeeoStore` 다.**
//
//  음표를 하나씩 찍고, 듣고, 고치는 것은 끝까지 무료다. 손을 덜어 주는 세 가지
//  (계이름 받아쓰기 · 글로 붙여넣기 · 사진 자동 채보)만 Pro 이고, 각각 세 번씩 무료로 써 본다.
//
//  이 파일이 정하는 것:
//   · 상품 ID (`ProProduct`) — App Store Connect · Products.storekit 과 같아야 한다.
//   · 세 번 체험을 세는 곳 (`ProFeature`, `ProAccess.recordUse`)
//   · 지금 열려 있는가 (`ProAccess.allows`)
//
//  ⚠️ 상품 로드·구매·복원·거래 리스너(다른 기기, 가족 공유, 환불, 만료)는 LeeoStore 안에 있다.
//     여기서 StoreKit 을 직접 쥐지 않는다.
//

import Foundation
import Combine
import StoreKit
import SwiftUI
import LeeoKit

// MARK: - 상품

/// App Store Connect · Products.storekit 과의 계약 — 한 번 정하면 바꾸지 않는다.
/// 주 · 월 · 연 구독은 구독 그룹 "StaffSinger Pro" 하나에 둔다.
enum ProProduct {
    private static let base = "com.devkoan.StaffSinger.pro"
    static let weekly   = base + ".weekly"
    static let monthly  = base + ".monthly"
    static let yearly   = base + ".yearly"
    static let lifetime = base + ".lifetime"
    /// 구독 졸업 — 구독 중인 사람에게만 보이는 평생가.
    static let graduate = base + ".graduate"

    static let subscriptions: Set<String> = [weekly, monthly, yearly]
    static let lifetimes: Set<String> = [lifetime, graduate]

    /// 불러올 순서. 팁 상품은 여기 넣지 않는다 — 팁은 아무것도 열지 않는다.
    static let all: [String] = [yearly, lifetime, monthly, weekly, graduate]
}

// MARK: - Pro 기능

/// 세 번씩 무료로 써 볼 수 있는 Pro 기능.
enum ProFeature: String, CaseIterable, Identifiable {
    /// 계이름 받아쓰기 (music.mic · DictationSheet)
    case dictation
    /// 글로 붙여넣기의 '악보로 변환' (doc.on.clipboard · PasteScoreSheet)
    case paste
    /// 참고 사진의 자동 채보 (ReferenceOverlay · OMR)
    case transcribe

    /// 무료로 써 볼 수 있는 횟수.
    static let freeUses = 3

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation:  String(localized: "계이름 받아쓰기", comment: "Pro feature name: solfège dictation")
        case .paste:      String(localized: "글로 붙여넣기", comment: "Pro feature name: paste a score written as text")
        case .transcribe: String(localized: "사진 자동 채보 (실험)", comment: "Pro feature name: read notes from a photo (experimental)")
        }
    }

    var systemImage: String {
        switch self {
        case .dictation:  "music.mic"
        case .paste:      "doc.on.clipboard"
        case .transcribe: "camera.viewfinder"
        }
    }
}

// MARK: - 권한

@MainActor
@Observable
final class ProAccess {

    static let shared = ProAccess()

    @ObservationIgnored let store: LeeoStore

    /// 산 것 · 구독 중인 것 · 페이월 전에 설치한 사람.
    private(set) var hasPro: Bool = false
    private(set) var products: [Product] = []
    private(set) var ownedProductIDs: Set<String> = []
    /// 지금 살아 있는 구독. 있으면 설정에 '평생으로 바꾸기' 가 선다.
    private(set) var subscription: LeeoGraduation.Subscription?
    private(set) var isWorking = false
    /// 사다가 막혔을 때 화면에 그대로 보여 줄 말.
    private(set) var failureMessage: String?
    /// 기능마다 지금까지 쓴 횟수.
    private(set) var uses: [ProFeature: Int] = [:]

    /// **이 기기가 스토어에서 Pro 상품을 한 번이라도 불러왔는가.**
    ///
    /// 상품을 App Store Connect 에 만들기 전에 빌드가 나가면 아무도 살 수 없다. 그때 세 번 뒤에
    /// 막으면 사지도 못하고 막히기만 한다. 그래서 한 번도 못 불러온 기기는 막지 않는다.
    /// 한 번 불러온 기기는 그 뒤 잠깐 네트워크가 끊겨도 다시 막는다(살 수 있는 상품이 있다는 걸 안다).
    private(set) var sellsPro: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observation: AnyCancellable?

    private static let sellsProKey = "pro.sellsPro"
    private static func usesKey(_ feature: ProFeature) -> String { "pro.uses." + feature.rawValue }

    init(defaults: UserDefaults = .standard) {
        guard let config = StaffSingerSpec.paywall else {
            preconditionFailure("계약에 페이월이 없다. StaffSingerSpec.monetization 을 확인할 것")
        }
        self.defaults = defaults
        sellsPro = defaults.bool(forKey: Self.sellsProKey)
        uses = Dictionary(uniqueKeysWithValues: ProFeature.allCases.map {
            ($0, defaults.integer(forKey: Self.usesKey($0)))
        })
        store = LeeoStore(config: config, grandfather: { await ProAccess.installedBeforePaywall() })
        // ⚠️ objectWillChange 는 값이 바뀌기 **직전**에 온다. 다음 차례로 미뤄서 읽는다.
        observation = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.pull() }
        }
        pull()
    }

    // MARK: 열려 있는가

    /// 이 기능을 지금 써도 되는가. 안 되면 페이월을 띄운다.
    func allows(_ feature: ProFeature) -> Bool {
        guard sellsPro else { return true }
        return store.gate.evaluate(feature.rawValue, current: uses[feature, default: 0]).isAllowed
    }

    /// 남은 무료 체험 횟수. Pro 이거나 아직 팔지 않으면 nil (세지 않는다).
    func freeUsesLeft(_ feature: ProFeature) -> Int? {
        guard sellsPro else { return nil }
        return store.gate.remaining(feature.rawValue, current: uses[feature, default: 0])
    }

    /// 기능을 실제로 한 번 썼다(음표가 악보에 들어갔다). 실패한 시도는 세지 않는다.
    func recordUse(_ feature: ProFeature) {
        let count = uses[feature, default: 0] + 1
        uses[feature] = count
        defaults.set(count, forKey: Self.usesKey(feature))
    }

    /// 평생 Pro(평생 · 구독 졸업)를 가졌는가.
    var ownsLifetime: Bool { !ownedProductIDs.isDisjoint(with: ProProduct.lifetimes) }

    func product(_ id: String) -> Product? { products.first { $0.id == id } }

    // MARK: 상태 맞추기

    /// 영수증을 다시 읽고 상품을 불러온다. 앱이 켜질 때와 다시 앞에 올 때마다 부른다.
    func refresh() async {
        await store.refreshEntitlements()
        await store.loadProducts()
        subscription = await LeeoGraduation.currentSubscription(among: ProProduct.subscriptions)
        pull()
    }

    func loadProducts() async {
        await store.loadProducts()
        pull()
    }

    /// **구독 졸업을 제안할 때인가.** 6개월째와 갱신 7일 전에 한 번씩 (→ LeeoGraduation).
    /// 이미 평생을 가졌으면 제안하지 않는다. 띄운 쪽이 `markGraduationOffered()` 를 부른다.
    var graduationIsDue: Bool {
        guard let subscription, !ownsLifetime, product(ProProduct.graduate) != nil else { return false }
        return LeeoGraduation.isDue(subscription, lastOffered: LeeoGraduation.lastOffered())
    }

    func markGraduationOffered() { LeeoGraduation.markOffered() }

    // MARK: 사기 / 되찾기

    /// ⚠️ `action` 은 페이월의 `@Environment(\.purchase)` 다. 결제 시트가 이 창에 뜬다
    ///    (아이패드에서 엉뚱한 창에 뜨면 결제가 오류로 끝난다).
    func purchase(_ product: Product, using action: PurchaseAction) async {
        _ = await store.purchase(product) { try await action($0) }
        subscription = await LeeoGraduation.currentSubscription(among: ProProduct.subscriptions)
        pull()
    }

    /// 기기를 바꿨거나 앱을 지웠다 받은 사람이 되찾는 길. 심사에서도 요구한다.
    func restore() async {
        await store.restore()
        subscription = await LeeoGraduation.currentSubscription(among: ProProduct.subscriptions)
        pull()
        if !hasPro, failureMessage == nil {
            failureMessage = String(localized: "이 Apple 계정에서 구매한 기록을 찾지 못했습니다.",
                                    comment: "Restore purchases: nothing found")
        }
    }

    // MARK: -

    private func pull() {
        hasPro = store.hasPro
        products = store.products
        ownedProductIDs = store.purchasedProductIDs
        isWorking = store.purchasingProductID != nil || store.isRestoring
        failureMessage = store.lastError
        // 팔 수 있는 Pro 상품이 하나라도 보였으면 그때부터 세 번 체험이 걸린다.
        if !sellsPro, products.contains(where: { ProProduct.all.contains($0.id) }) {
            sellsPro = true
            defaults.set(true, forKey: Self.sellsProKey)
        }
    }

    // MARK: - 페이월 전에 설치한 사람

    /// 페이월이 없던 마지막 빌드(1.0.6 빌드 8). 이 빌드까지 받은 사람은 Pro 를 그대로 쓴다.
    /// 받아쓰기 · 붙여넣기 · 채보를 무료로 쓰던 사람에게서 뺏지 않는다.
    nonisolated static let lastBuildBeforePaywall = 8

    /// App Store 가 서명한 최초 다운로드 빌드로 알아본다. 지웠다 다시 받아도 같다.
    /// 시험 환경(Xcode · 샌드박스)은 최초 빌드가 엉뚱하게 오므로 출시 영수증만 믿는다.
    static func installedBeforePaywall() async -> Bool {
        guard case .verified(let app)? = try? await AppTransaction.shared,
              app.environment == .production else { return false }
        return isBuildBeforePaywall(app.originalAppVersion)
    }

    /// `originalAppVersion` 은 iOS 에서 CFBundleVersion(빌드 번호)이다.
    nonisolated static func isBuildBeforePaywall(_ originalAppVersion: String) -> Bool {
        guard let build = Int(originalAppVersion.split(separator: ".").first ?? "") else { return false }
        return build <= lastBuildBeforePaywall
    }
}
