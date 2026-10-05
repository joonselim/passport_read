# passport_read

An iPhone app that reads an ePassport chip over NFC, has a server check it, and keeps the issued Digital ID on the iPhone.

## Why

A toy project to understand the standards behind wallet identity, mainly ICAO 9303 (ePassports).
The phone reads the passport chip, and a separate server checks that the data was signed by the issuing country.

## You need two repos

| Repo | Role |
|---|---|
| **passport_read** (this one) | iPhone app. Scans the passport, reads the chip, sends the data to the server |
| [**passport_validate**](https://github.com/joonselim/passport_validate) | Java server. Checks that the data is genuine |

The app works alone up to reading the chip. Adding and presenting a Digital ID needs passport_validate running.

## How it works

1. The home screen lists your Digital IDs. Tap **Add passport**.
2. Scan the two MRZ lines with the camera, confirm the values, and hold the passport to the phone. The app reads DG1 (personal data), DG2 (photo) and SOD (signature) from the chip.
3. Tap **Verify and add to iPhone**. After Face ID, the app makes a key in the Secure Enclave and signs the server's challenge with it. It encrypts the chip files and the public key with the server's key (HPKE) and sends them.
4. If the passport passes, the server issues a Digital ID in the ISO 18013-5 mdoc shape, bound to that key. The app saves it in the Keychain, on this iPhone only.
5. Tap an ID to see the photo, name and masked details (Face ID shows them in full). **Present ID** sends only the fields a demo verifier asks for, signed by the device key.

## Structure

```
project.yml                      XcodeGen project definition
Sources/
  WalletView.swift               Home: list of Digital IDs + Add passport
  IDDetailView.swift             One ID: photo, masked details, present, remove
  PresentView.swift              Share chosen fields with the demo verifier
  AddPassportView.swift          Scan, read the chip, verify, add
  MRZScannerView.swift           Camera + text recognition for the MRZ
  PassportReaderViewModel.swift  Reads the chip, gets the ID issued, saves it
  DigitalID.swift                Saved ID, decoded fields, masking
  DeviceKey.swift                Secure Enclave key + Face ID
  WalletStore.swift              Keychain storage
  CBOR.swift                     Small CBOR encoder/decoder
  VerificationClient.swift       HTTP calls + HPKE encryption
  PipelineView.swift             The 10-step progress list
  PassportUtils.swift            Builds the key that unlocks the chip
  PassportDetailView.swift       Raw passport data + JSON export
```

## Not the same as Apple Wallet

- The key is in the Secure Enclave. Wallet IDs live in the Secure Element, which other apps cannot use.
- There is no App Attest, so the server cannot prove the key came from a real iPhone.
- There is no selfie or liveness check, so anyone holding the passport could add it.
- Only the mdoc data and signatures are implemented, not the ISO 18013-5 NFC/Bluetooth transport.

## Run

Requirements: Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), a real iPhone (NFC does not work in the simulator), and a paid Apple Developer account (NFC needs it).

1. In `project.yml`, set `DEVELOPMENT_TEAM` to your team ID.
2. Generate the project and open it:
   ```bash
   brew install xcodegen
   xcodegen generate
   open PassportReader.xcodeproj
   ```
3. Start passport_validate on your Mac. In `project.yml`, set `HPKEServerPublicKey` to the `hpkePublicKey` value from `GET /api/v1/passport/health`, then run `xcodegen generate` again.
4. Pick your iPhone and press Run.
5. In the app, open **Advanced** and set the server address to `http://<your Mac's IP>:8080`. The phone and Mac must be on the same Wi-Fi.

## Libraries

- [NFCPassportReader](https://github.com/AndyQ/NFCPassportReader): chip access (BAC/PACE) and reading data groups
