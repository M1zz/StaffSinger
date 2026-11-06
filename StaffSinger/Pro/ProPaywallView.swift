//
//  ProPaywallView.swift
//  StaffSinger
//
//  초견 Pro 를 파는 한 장, 그리고 설정의 Pro 줄.
//
//  **무료인 것을 먼저 말한다.** 비교표의 위 네 줄은 무료 · Pro 모두 ✓ 다. 이 화면은
//  "안 사면 못 쓴다"가 아니라 "적고 듣는 건 전부 무료이고, 손을 덜어 주는 것만 값을 받는다"는 말이다.
//
//  고르는 길: 연 구독(기본) · 평생, 펼치면 주 · 월. 첫 해 할인(App Store 첫 구독 할인)과
//  "연 구독 N년치" 한 줄은 `LeeoTermPicker` 가 알아서 보인다.
//  스토어에서 불러온 상품만 단추가 된다 — 아직 없는 상품은 서지 않는다.
//

import SwiftUI
import StoreKit
import LeeoKit

struct ProPaywallView: View {
    /// 어디서 막혀 들어왔는가. 그 줄을 비교표에서 강조한다.
    var highlight: ProFeature?

    @State private var pro = ProAccess.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// 결제 시트를 **이 페이월이 떠 있는 창**에 띄운다.
    @Environment(\.purchase) private var purchaseAction

    @State private var term: LeeoPlanTerm = .yearly
    /// 펼쳐서 고른 주 · 월 구독. 고르면 연 / 평생 대신 이것을 산다.
    @State private var shortPlanID: String?
    @State private var loadingProducts = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    comparison
                    if pro.hasPro {
                        Label("초견 Pro 를 쓰고 있어요. 고마워요.", systemImage: "checkmark.seal.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    } else {
                        plans
                    }
                    if let message = pro.failureMessage, !pro.products.isEmpty {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.body)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    legal
                }
                .padding(24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("초견 Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("나중에", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("구매 복원") {
                        Task {
                            await pro.restore()
                            if pro.hasPro { dismiss() }
                        }
                    }
                    .disabled(pro.isWorking)
                }
            }
            .task { await loadPlans() }
        }
    }

    // MARK: 머리

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("초견 Pro")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text("말하면 받아 적고, 사진을 찍으면 채워 줍니다. 연 구독이나 평생 중에 고르세요.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let highlight, !pro.hasPro {
                Label("\(highlight.title) 무료 체험 \(ProFeature.freeUses)번을 모두 썼어요.",
                      systemImage: highlight.systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 비교표

    private var comparison: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("기능")
                Text("무료").gridColumnAlignment(.center)
                Text("Pro").gridColumnAlignment(.center)
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
            Divider()
            freeRow("음표 입력 · 재생 · 메트로놈")
            freeRow("화음 · 성부 · 조표 · 자리표")
            freeRow("참고 사진")
            freeRow("지금 악보 글로 복사")
            ForEach(ProFeature.allCases) { proRow($0) }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func freeRow(_ title: LocalizedStringKey) -> some View {
        GridRow {
            Text(title).fixedSize(horizontal: false, vertical: true)
            check
            check
        }
        .font(.body)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text("무료"))
    }

    private func proRow(_ feature: ProFeature) -> some View {
        let trial = String(localized: "\(ProFeature.freeUses)번 체험",
                           comment: "Paywall comparison: free column for a Pro feature. %lld = number of free tries")
        return GridRow {
            Text(feature.title).fixedSize(horizontal: false, vertical: true)
            Text(trial).foregroundStyle(.secondary).multilineTextAlignment(.center)
            check
        }
        .font(.body.weight(feature == highlight ? .semibold : .regular))
        .foregroundStyle(feature == highlight ? Color.accentColor : .primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(feature.title))
        .accessibilityValue(Text("무료는 \(trial), Pro 는 제한 없음"))
    }

    private var check: some View {
        Image(systemName: "checkmark")
            .font(.body.weight(.bold))
            .foregroundStyle(Color.accentColor)
            .frame(minWidth: 44)
    }

    // MARK: 요금제

    @ViewBuilder
    private var plans: some View {
        let yearly = pro.product(ProProduct.yearly)
        let lifetime = pro.product(ProProduct.lifetime)
        if yearly == nil && lifetime == nil {
            plansStatus
        } else {
            VStack(alignment: .leading, spacing: 12) {
                LeeoTermPicker(term: Binding(get: { term }, set: { term = $0; shortPlanID = nil }),
                               yearly: yearly, lifetime: lifetime)
                    .opacity(shortPlanID == nil ? 1 : 0.5)
                shortPlans
                buyButton
            }
        }
    }

    /// 주 · 월 구독. 연 구독이 기본이라 펼쳐야 보인다. 불러온 상품만 줄이 선다.
    @ViewBuilder
    private var shortPlans: some View {
        let short = [pro.product(ProProduct.monthly), pro.product(ProProduct.weekly)].compactMap { $0 }
        if !short.isEmpty {
            DisclosureGroup("주 · 월 구독 보기") {
                VStack(spacing: 4) {
                    ForEach(short, id: \.id) { shortPlanRow($0) }
                }
                .padding(.top, 6)
            }
            .font(.body)
        }
    }

    private func shortPlanRow(_ product: Product) -> some View {
        let selected = shortPlanID == product.id
        let title = product.id == ProProduct.weekly
            ? String(localized: "주 구독 · \(product.displayPrice) / 주", comment: "Paywall: weekly plan row. %@ = price")
            : String(localized: "월 구독 · \(product.displayPrice) / 월", comment: "Paywall: monthly plan row. %@ = price")
        return Button {
            shortPlanID = selected ? nil : product.id
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 지금 고른 상품.
    private var chosen: Product? {
        if let shortPlanID { return pro.product(shortPlanID) }
        return pro.product(term == .yearly ? ProProduct.yearly : ProProduct.lifetime)
    }

    private var buyTitle: String {
        switch shortPlanID {
        case ProProduct.weekly?:  String(localized: "주 구독 시작")
        case ProProduct.monthly?: String(localized: "월 구독 시작")
        default: term == .yearly ? String(localized: "연 구독 시작") : String(localized: "평생으로 사기")
        }
    }

    private var buyButton: some View {
        Button {
            guard let chosen else { return }
            Task {
                await pro.purchase(chosen, using: purchaseAction)
                if pro.hasPro { dismiss() }
            }
        } label: {
            Group {
                if pro.isWorking {
                    ProgressView().tint(.white)
                } else {
                    Text(buyTitle).font(.headline)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(pro.isWorking || chosen == nil)
    }

    @ViewBuilder
    private var plansStatus: some View {
        if loadingProducts {
            HStack(spacing: 10) {
                ProgressView()
                Text("요금제를 불러오는 중…").font(.body).foregroundStyle(.secondary)
            }
        } else {
            // 한 번 실패하면 죽은 단추로 남지 않게, 그 자리에서 다시 청한다.
            VStack(alignment: .leading, spacing: 10) {
                Text("요금제를 불러오지 못했습니다. 인터넷 연결을 확인하고 다시 불러와 주세요.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await loadPlans() }
                } label: {
                    Label("다시 불러오기", systemImage: "arrow.clockwise").font(.body.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// 첫 조회가 비어 오면 한 번 더 청한다. 샌드박스(심사 환경)는 첫 조회가 빈손으로 오는 일이 잦다.
    private func loadPlans() async {
        loadingProducts = true
        await pro.loadProducts()
        if pro.products.isEmpty {
            try? await Task.sleep(for: .seconds(1.5))
            await pro.loadProducts()
        }
        loadingProducts = false
    }

    // MARK: 약관 (구독을 파는 앱의 심사 필수 항목)

    private var legal: some View {
        VStack(alignment: .leading, spacing: 10) {
            if pro.products.contains(where: { $0.subscription != nil }) {
                Text("구독은 기간이 끝나기 24시간 전까지 해지하지 않으면 같은 요금으로 자동 갱신되며, Apple 계정으로 결제됩니다. 처음 연 구독을 시작하면 첫 해는 할인된 값으로 결제되고, 그 뒤에는 정가로 갱신됩니다. 해지와 관리는 App Store 계정 설정에서 합니다. 평생은 구독이 아니라 한 번 결제입니다.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 20) {
                if let terms = StaffSingerSpec.monetization.subscriptionTermsURL {
                    Button("이용약관") { openURL(terms) }
                }
                Button("개인정보 처리방침") { openURL(StaffSingerSpec.legal.privacyURL) }
            }
            .font(.body)
        }
    }
}

// MARK: - 구독 졸업

/// 구독 중인 사람에게 평생으로 옮겨 갈 값을 보인다. 사면 구독 관리 화면으로 해지를 돕는다.
struct ProGraduationSheet: View {
    @State private var pro = ProAccess.shared

    var body: some View {
        LeeoGraduationOfferView(graduate: pro.product(ProProduct.graduate)) {
            await pro.refresh()
        }
        .task { if pro.product(ProProduct.graduate) == nil { await pro.loadProducts() } }
    }
}

// MARK: - 설정의 Pro 줄

/// 설정 ▸ 초견 Pro. 무료면 페이월로, 구독 중이면 구독 관리와 '평생으로 바꾸기', 복원은 늘.
struct ProSettingsSection: View {
    @State private var pro = ProAccess.shared
    @State private var showPaywall = false
    @State private var showGraduation = false
    @State private var showManage = false
    @State private var restoreMessage: String?

    var body: some View {
        Section {
            if !pro.hasPro {
                Button { showPaywall = true } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("초견 Pro", systemImage: "sparkles")
                            .font(.body.weight(.semibold))
                        Text("계이름 받아쓰기 · 글로 붙여넣기 · 사진 자동 채보를 제한 없이")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if pro.ownsLifetime {
                Label("초견 Pro 평생 사용 중", systemImage: "checkmark.seal.fill")
            } else if pro.subscription != nil {
                Label("초견 Pro 구독 중", systemImage: "checkmark.seal.fill")
                Button { showManage = true } label: {
                    Label("구독 관리", systemImage: "creditcard")
                }
                Button { showGraduation = true } label: {
                    Label(LeeoLadderText.switchToLifetimeEntry, systemImage: "graduationcap")
                }
            } else {
                // 페이월 전에 설치한 사람 · 가족 공유로 받은 사람.
                Label("초견 Pro 사용 중", systemImage: "checkmark.seal.fill")
            }
            Button {
                Task {
                    await pro.restore()
                    restoreMessage = pro.hasPro ? nil : pro.failureMessage
                }
            } label: {
                Label("구매 복원", systemImage: "arrow.clockwise")
            }
            .disabled(pro.isWorking)
        } header: {
            Text("초견 Pro")
        } footer: {
            if let restoreMessage { Text(restoreMessage) }
        }
        .sheet(isPresented: $showPaywall) { ProPaywallView() }
        .sheet(isPresented: $showGraduation) { ProGraduationSheet() }
        .manageSubscriptionsSheet(isPresented: $showManage)
    }
}
