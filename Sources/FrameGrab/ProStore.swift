import Foundation
import StoreKit

final class ProStore {
    static let productID = "com.appblit.nicegrab.pro"

    private(set) var isPro = false
    private(set) var product: Product?
    private var updatesTask: Task<Void, Never>?
    private let didChange: () -> Void

    init(didChange: @escaping () -> Void) {
        self.didChange = didChange
        updatesTask = observeTransactions()
        Task { await refresh() }
    }

    deinit {
        updatesTask?.cancel()
    }

    var purchaseTitle: String {
        if let product {
            return "Buy NiceGrab Pro — \(product.displayPrice)"
        }
        return "Buy NiceGrab Pro…"
    }

    func refresh() async {
        do {
            product = try await Product.products(for: [Self.productID]).first
        } catch {
            // Entitlements can still be checked when product metadata is unavailable.
        }
        await refreshEntitlement()
    }

    func purchase() async throws {
        let product: Product
        if let loadedProduct = self.product {
            product = loadedProduct
        } else {
            guard let loadedProduct = try await Product.products(for: [Self.productID]).first else {
                throw ProStoreError.productUnavailable
            }
            self.product = loadedProduct
            product = loadedProduct
        }

        switch try await product.purchase() {
        case .success(let result):
            let transaction = try verified(result)
            await transaction.finish()
            await refreshEntitlement()
        case .pending:
            throw ProStoreError.pending
        case .userCancelled:
            return
        @unknown default:
            return
        }
    }

    func restore() async throws {
        try await AppStore.sync()
        await refreshEntitlement()
    }

    private func observeTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if let transaction = try? self.verified(result) {
                    await transaction.finish()
                }
                await self.refreshEntitlement()
            }
        }
    }

    private func refreshEntitlement() async {
        var entitled = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? verified(result) else { continue }
            if transaction.productID == Self.productID, transaction.revocationDate == nil {
                entitled = true
                break
            }
        }

        let entitlementValue = entitled
        await MainActor.run {
            let changed = self.isPro != entitlementValue
            self.isPro = entitlementValue
            if changed || self.product != nil { self.didChange() }
        }
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): return value
        case .unverified: throw ProStoreError.failedVerification
        }
    }
}

enum ProStoreError: LocalizedError {
    case productUnavailable
    case failedVerification
    case pending

    var errorDescription: String? {
        switch self {
        case .productUnavailable: "NiceGrab Pro is temporarily unavailable. Please try again later."
        case .failedVerification: "The App Store could not verify this purchase."
        case .pending: "The purchase is pending approval. Pro will unlock automatically when it is approved."
        }
    }
}
