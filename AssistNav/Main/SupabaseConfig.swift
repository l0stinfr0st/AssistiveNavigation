import Foundation

enum SupabaseConfig {
    static var url: URL {
        guard let s = loadPlistString("SUPABASE_URL"), let u = URL(string: s), !s.isEmpty else {
            fatalError("Missing SUPABASE_URL in SupabaseConfig.plist (see SupabaseConfig.example.plist).")
        }
        return u
    }

    static var anonKey: String {
        guard let k = loadPlistString("SUPABASE_ANON_KEY"), !k.isEmpty else {
            fatalError("Missing SUPABASE_ANON_KEY in SupabaseConfig.plist.")
        }
        return k
    }

    private static func loadPlistString(_ key: String) -> String? {
        guard let url = Bundle.main.url(forResource: "SupabaseConfig", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: Any]
        else { return nil }
        return dict[key] as? String
    }
}
