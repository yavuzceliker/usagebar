import Foundation

/// Reads the OAuth token Claude Code already keeps for a config dir (macOS Keychain,
/// falling back to <config dir>/.credentials.json) and asks Anthropic for the plan's rate-limit usage.
/// Read-only: the token is never refreshed or written, so Claude Code's own login stays intact.
enum ClaudeProvider {
    private struct Credentials {
        let accessToken: String
        let expiresAt: Date?
        let plan: String?
    }

    private static func parseCredentials(_ data: Data) -> Credentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expires = number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credentials(accessToken: token, expiresAt: expires, plan: oauth["subscriptionType"] as? String)
    }

    private static func keychainCredentials(service: String) -> Credentials? {
        // Going through /usr/bin/security matches how Claude Code writes the item,
        // so macOS does not show an extra Keychain access prompt.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parseCredentials(data)
    }

    private static func fileCredentials(configDir: String) -> Credentials? {
        guard let data = FileManager.default.contents(atPath: configDir + "/.credentials.json") else { return nil }
        return parseCredentials(data)
    }

    private static func allCredentials(configDir: String, isDefault: Bool) -> [Credentials] {
        let services = AccountDiscovery.claudeKeychainServices(configDir: configDir, isDefault: isDefault)
        return (services.map { keychainCredentials(service: $0) } + [fileCredentials(configDir: configDir)]).compactMap { $0 }
    }

    static func hasCredentials(configDir: String, isDefault: Bool) -> Bool {
        !allCredentials(configDir: configDir, isDefault: isDefault).isEmpty
    }

    private static func loadCredentials(_ account: Account) throws -> Credentials {
        let candidates = allCredentials(configDir: account.source, isDefault: account.isDefault)
        guard let best = candidates.max(by: { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) }) else {
            throw UsageError(short: L.offline, long: L.claudeNoCreds)
        }
        if let exp = best.expiresAt, exp < Date() {
            throw UsageError(short: L.offline, long: L.claudeExpired)
        }
        return best
    }

    static func fetch(_ account: Account) async throws -> Snapshot {
        let creds = try loadCredentials(account)
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("UsageBar/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw UsageError(short: L.offline, long: L.claudeExpired) }
        if status == 429 {
            let wait = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw UsageError(short: "…", long: L.rateLimited, retryAfter: wait, isRateLimit: true)
        }
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError(short: L.offline, long: "Claude API HTTP \(status)")
        }
        return parse(json, plan: creds.plan)
    }

    static func parse(_ json: [String: Any], plan: String?) -> Snapshot {
        func meter(_ key: String, _ label: String) -> UsageMeter? {
            guard let window = json[key] as? [String: Any] else { return nil }
            let pct = number(window["utilization"])
            let detail = parseISODate(window["resets_at"]).map { L.resetsIn(formatCountdown(to: $0)) }
            return UsageMeter(id: key, label: label, percent: pct, detail: detail)
        }

        // Session + weekly always come first: they are the two menu bar bars.
        let session = meter("five_hour", L.session) ?? UsageMeter(id: "five_hour", label: L.session, percent: nil, detail: nil)
        let weekly = meter("seven_day", L.weekly) ?? UsageMeter(id: "seven_day", label: L.weekly, percent: nil, detail: nil)
        var meters = [session, weekly]
        if let m = meter("seven_day_opus", L.weeklyOpus) { meters.append(m) }
        if let m = meter("seven_day_sonnet", L.weeklySonnet) { meters.append(m) }

        // Extra (pay-as-you-go) usage, if the account has it turned on.
        var extraUsed: Double?
        var extraLimit: Double?
        var currency = "USD"
        if let spend = json["spend"] as? [String: Any], (spend["enabled"] as? Bool) == true {
            func money(_ any: Any?) -> Double? {
                guard let m = any as? [String: Any], let minor = number(m["amount_minor"]) else { return nil }
                if let c = m["currency"] as? String { currency = c }
                return minor / pow(10, number(m["exponent"]) ?? 2)
            }
            extraUsed = money(spend["used"]) ?? 0
            extraLimit = money(spend["limit"])
        } else if let extra = json["extra_usage"] as? [String: Any], (extra["is_enabled"] as? Bool) == true {
            let scale = pow(10, number(extra["decimal_places"]) ?? 2)
            if let c = extra["currency"] as? String { currency = c }
            extraUsed = (number(extra["used_credits"]) ?? 0) / scale
            extraLimit = number(extra["monthly_limit"]).map { $0 / scale }
        }

        let sessionPct = session.percent ?? 0
        let weeklyPct = weekly.percent ?? 0
        var ratio = max(sessionPct, weeklyPct) / 100
        var amounts: [Amount] = []
        let headline: String
        if let used = extraUsed {
            headline = formatMoney(used, currency: currency)
            amounts.append(Amount(label: L.extraUsage, value: formatMoney(used, currency: currency), emphasized: true))
            if let limit = extraLimit, limit > 0 {
                amounts.append(Amount(label: L.limit, value: formatMoney(limit, currency: currency), emphasized: false))
                ratio = max(ratio, used / limit)
            }
        } else {
            headline = "\(Int(sessionPct.rounded()))% · \(Int(weeklyPct.rounded()))%"
        }
        if let plan, !plan.isEmpty {
            amounts.append(Amount(label: L.plan, value: plan.capitalized, emphasized: false))
        }

        return Snapshot(headline: headline, ratio: ratio, meters: meters,
                        amounts: amounts, footnote: nil,
                        activityKey: sessionPct + weeklyPct + (extraUsed ?? 0) * 100)
    }
}
