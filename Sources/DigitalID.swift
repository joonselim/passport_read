import Foundation
import UIKit

/// A Digital ID saved on this iPhone: what the issuer signed, plus the device key it is bound to.
struct StoredID: Codable, Identifiable, Hashable {
    let id: UUID
    let docType: String
    let issuerAuth: Data          // COSE_Sign1: the issuer's signature over the field hashes and the device key
    let items: [Item]             // every signed field
    let deviceKey: Data           // Secure Enclave key blob; only this iPhone can use it
    let addedAt: Date

    /// One signed field.
    struct Item: Codable, Hashable {
        let namespace: String
        let elementIdentifier: String
        let bytes: Data           // IssuerSignedItemBytes (CBOR)
    }

    /// Field values decoded from the signed items, for display.
    var claims: IDClaims { IDClaims(self) }
}

/// Readable values of a Digital ID.
struct IDClaims {
    var familyName = ""
    var givenName = ""
    var birthDate = ""            // YYYY-MM-DD
    var expiryDate = ""           // YYYY-MM-DD
    var documentNumber = ""
    var nationality = ""
    var sex = ""
    var portrait: UIImage?
    var ageOver21: Bool?
    var validUntil: Date?

    /// Reads each signed item (tag 24 around a map) and the validity from the issuer's MSO.
    init(_ id: StoredID) {
        for item in id.items {
            guard let wrapped = try? CBOR.decode(item.bytes),
                  let inner = wrapped.data.flatMap({ try? CBOR.decode($0) }),
                  let value = inner["elementValue"] else { continue }
            switch item.elementIdentifier {
            case "family_name": familyName = value.text ?? ""
            case "given_name": givenName = value.text ?? ""
            case "birth_date": birthDate = value.text ?? ""
            case "expiry_date": expiryDate = value.text ?? ""
            case "document_number": documentNumber = value.text ?? ""
            case "nationality": nationality = value.text ?? ""
            case "sex": sex = value.text ?? ""
            case "portrait": portrait = value.data.flatMap(UIImage.init(data:))
            case "age_over_21": ageOver21 = value.bool
            default: break
            }
        }
        if case .array(let parts)? = try? CBOR.decode(id.issuerAuth), parts.count == 4,
           let msoBytes = parts[2].data.flatMap({ try? CBOR.decode($0) })?.data,
           let mso = try? CBOR.decode(msoBytes),
           let until = mso["validityInfo"]?["validUntil"]?.text {
            validUntil = ISO8601DateFormatter().date(from: until)
        }
    }

    /// "GILDONG HONG"
    var fullName: String { [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ") }
}

/// Partly hides sensitive values on screen.
enum Mask {
    /// "M12345678" to "M1•••••78"
    static func documentNumber(_ s: String) -> String {
        guard s.count > 4 else { return s }
        return String(s.prefix(2)) + String(repeating: "•", count: s.count - 4) + String(s.suffix(2))
    }

    /// "1990-01-01" to "1990-••-••"
    static func birthDate(_ s: String) -> String {
        s.count == 10 ? String(s.prefix(4)) + "-••-••" : s
    }

    /// "2032-04-24" to "2032-04-••"
    static func expiryDate(_ s: String) -> String {
        s.count == 10 ? String(s.prefix(7)) + "-••" : s
    }
}

/// Human labels for field names.
enum FieldName {
    static func label(_ id: String) -> String {
        switch id {
        case "age_over_21": return "Over 21"
        case "age_over_18": return "Over 18"
        case "portrait": return "Photo"
        case "family_name": return "Last name"
        case "given_name": return "First name"
        case "birth_date": return "Date of birth"
        case "document_number": return "Passport number"
        case "expiry_date": return "Expiry date"
        case "nationality": return "Nationality"
        case "issuing_country": return "Issuing country"
        case "sex": return "Sex"
        default: return id
        }
    }
}
