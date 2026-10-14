import Foundation

/// Reads the Cursor session token from the account's local state DB (read-only) and asks
/// Cursor's dashboard API for the current billing period. The token is never stored.
enum CursorProvider {
    static func fetch(_ account: Account) async throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: account.source) else {
            throw UsageError(short: L.offline, long: L.cursorNoDB)
        }
        let token = AccountDiscovery.readCursorValues(account.source, keys: ["cursorAuth/accessToken"])["cursorAuth/accessToken"] ?? ""
        if token.isEmpty { throw UsageError(short: L.offline, long: L.cursorNoToken) }

        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError(short: L.offline, long: "Cursor API HTTP \(status)")
        }
        return parse(json)
    }

    static func parse(_ json: [String: Any]) -> Snapshot {
        let spend = json["spendLimitUsage"] as? [String: Any] ?? [:]
        func dollars(_ key: String) -> Double? { number(spend[key]).map { $0 / 100 } }

        let teamUsed = dollars("pooledUsed") ?? 0
        let mine = dollars("individualUsed") ?? 0
        let limit = dollars("pooledLimit") ?? dollars("individualLimit") ?? 0
        let isTeam = (spend["limitType"] as? String) == "team"

        var shown = teamUsed
        if !isTeam { shown = mine > 0 ? mine : teamUsed }
        let ratio = limit > 0 ? shown / limit : 0

        let headline = isTeam
            ? "\(formatMoney(teamUsed)) · \(formatMoney(mine))"
            : formatMoney(shown)

        var amounts: [Amount] = []
        if isTeam {
            amounts.append(Amount(label: "\(L.extraSpend) · \(L.team)", value: formatMoney(teamUsed), emphasized: true))
            amounts.append(Amount(label: "\(L.extraSpend) · \(L.you)", value: formatMoney(mine), emphasized: true))
        } else {
            amounts.append(Amount(label: L.extraSpend, value: formatMoney(shown), emphasized: true))
        }
        if limit > 0 { amounts.append(Amount(label: L.limit, value: formatMoney(limit), emphasized: false)) }

        let plan = json["planUsage"] as? [String: Any] ?? [:]
        if let total = number(plan["totalSpend"]) {
            var value = formatMoney(total / 100)
            if let included = number(plan["limit"] ?? plan["includedSpend"]) {
                value += " / " + formatMoney(included / 100) + " " + L.included
            }
            amounts.append(Amount(label: L.planSpend, value: value, emphasized: false))
        }

        let meters = [
            UsageMeter(id: "auto", label: L.autoMeter, percent: number(plan["autoPercentUsed"]), detail: nil),
            UsageMeter(id: "api", label: L.apiMeter, percent: number(plan["apiPercentUsed"]), detail: nil),
        ]

        var footnote: String?
        if let endMs = number(json["billingCycleEnd"]) {
            footnote = L.cycleEndsIn(formatCountdown(to: Date(timeIntervalSince1970: endMs / 1000)))
        }

        // Plan spend grows with nearly every request, so it is the best "just used" signal.
        let activity = teamUsed + mine + (number(plan["totalSpend"]) ?? 0) / 100
            + (number(plan["autoPercentUsed"]) ?? 0) + (number(plan["apiPercentUsed"]) ?? 0)
        return Snapshot(headline: headline, ratio: ratio, meters: meters,
                        amounts: amounts, footnote: footnote, activityKey: activity)
    }
}
