import Foundation

/// JSON coders configured for Supabase: timestamps are written as UTC RFC 3339 and read
/// with `AriaDate`'s lenient parser.
public enum AriaJSON {
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = AriaDate.parseTimestamp(text, defaultTimeZone: TimeZone(identifier: "UTC")!) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid timestamp \(text)")
            }
            return date
        }
        return decoder
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(AriaDate.formatUTC(date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
