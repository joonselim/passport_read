# passport_read

An iPhone app that reads an ePassport chip over NFC and asks a server whether the passport is genuine.

## Why

To mimic how Apple Wallet adds a Digital ID from a passport.
The phone scans the passport and reads its chip. A server checks that the data was really signed by the issuing country.

## You need two repos

| Repo | Role |
|---|---|
| **passport_read** (this one) | iPhone app. Scans the passport, reads the chip, sends the data to the server |
| [**passport_validate**](https://github.com/joonselim/passport_validate) | Java server. Checks that the data is genuine |

The app works alone up to reading the chip. The "Verify with server" step needs passport_validate running.

## How it works

1. Scan the two MRZ lines at the bottom of the photo page with the camera.
2. Confirm the passport number, date of birth and expiry date.
3. Hold the passport against the phone. The app reads DG1 (personal data), DG2 (photo) and SOD (signature) from the chip.
4. Tap **Verify with server**. The app sends the three files to the server and shows the result.

## Structure

```
project.yml                      XcodeGen project definition
Sources/
  ContentView.swift              Main screen
  MRZScannerView.swift           Camera + text recognition for the MRZ
  PassportReaderViewModel.swift  Reads the chip, calls the server
  PassportUtils.swift            Builds the key that unlocks the chip
  VerificationClient.swift       HTTP calls to the server
  PipelineView.swift             The 7-step progress list
  PassportDetailView.swift       All passport data + JSON export
```

## Run

Requirements: Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), a real iPhone (NFC does not work in the simulator), and a paid Apple Developer account (NFC needs it).

1. In `project.yml`, set `DEVELOPMENT_TEAM` to your team ID.
2. Generate the project and open it:
   ```bash
   brew install xcodegen
   xcodegen generate
   open PassportReader.xcodeproj
   ```
3. Pick your iPhone and press Run.
4. Start passport_validate on your Mac. In the app, open **Advanced** and set the server address to `http://<your Mac's IP>:8080`. The phone and Mac must be on the same Wi-Fi.

## Libraries

- [NFCPassportReader](https://github.com/AndyQ/NFCPassportReader): chip access (BAC/PACE) and reading data groups
