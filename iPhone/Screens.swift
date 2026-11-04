// SwiftUI screens: pairing, and themes & settings.
import AVFoundation
import ClamshellCore
import SwiftUI

struct PairingScreen: View {
  let onPair: (PairingInfo) -> Void
  @State private var scanning = false
  @State private var link = ""
  @State private var failed = false

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        Image(systemName: "macbook.and.iphone").font(.system(size: 56)).foregroundStyle(.tint).padding(.top, 50)
        Text("Pair with your Mac").font(.largeTitle.bold())
        Text("Open Clamshell Host on your Mac, then scan the code in its window.").multilineTextAlignment(.center).foregroundStyle(.secondary)

        if scanning {
          QRScanner { value in
            if let url = URL(string: value), let p = PairingInfo(url: url) { onPair(p) } else { failed = true }
            scanning = false
          }
          .frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 18))
        }
        Button { scanning.toggle() } label: {
          Label(scanning ? "Cancel" : "Scan Code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity).padding(8)
        }.buttonStyle(.borderedProminent)

        VStack(alignment: .leading, spacing: 8) {
          Text("Or paste the pairing link").font(.footnote).foregroundStyle(.secondary)
          HStack {
            TextField("clamshell://pair?…", text: $link).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Pair") {
              if let url = URL(string: link), let p = PairingInfo(url: url) { onPair(p) } else { failed = true }
            }.disabled(link.isEmpty)
          }
        }
        if failed { Text("That isn't a Clamshell pairing code.").foregroundStyle(.red).font(.footnote) }
      }
      .padding(24).frame(maxWidth: 520)
      .frame(maxWidth: .infinity)
    }
  }
}

struct QRScanner: UIViewControllerRepresentable {
  let onFound: (String) -> Void
  func makeUIViewController(context: Context) -> ScannerController { ScannerController(onFound: onFound) }
  func updateUIViewController(_ c: ScannerController, context: Context) {}

  final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let capture = AVCaptureSession()
    private let onFound: (String) -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    private var done = false
    init(onFound: @escaping (String) -> Void) { self.onFound = onFound; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
      super.viewDidLoad()
      view.backgroundColor = .black
      guard let cam = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: cam), capture.canAddInput(input) else { return }
      capture.addInput(input)
      let output = AVCaptureMetadataOutput()
      guard capture.canAddOutput(output) else { return }
      capture.addOutput(output)
      output.setMetadataObjectsDelegate(self, queue: .main)
      output.metadataObjectTypes = [.qr]
      let p = AVCaptureVideoPreviewLayer(session: capture)
      p.videoGravity = .resizeAspectFill
      view.layer.addSublayer(p)
      preview = p
      DispatchQueue.global(qos: .userInitiated).async { [capture] in capture.startRunning() }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); capture.stopRunning() }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
      guard !done, let v = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
      done = true
      onFound(v)
    }
  }
}

struct SettingsScreen: View {
  @ObservedObject var settings: AppSettings
  @ObservedObject var session: PhoneSession
  let currentProfile: () -> GestureProfile
  let onForget: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var confirmForget = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Theme") {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: 12) {
            ForEach(Theme.all) { t in
              Button { settings.theme = t.id } label: {
                VStack(spacing: 6) {
                  MiniLaptop(theme: t)
                  Text(t.name).font(.caption).foregroundStyle(.primary)
                }
                .padding(8).frame(maxWidth: .infinity)
                .background(settings.theme == t.id ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(settings.theme == t.id ? Color.accentColor : .clear, lineWidth: 2))
              }.buttonStyle(.plain)
            }
          }
        }

        Section("Gestures") {
          Picker("Profile", selection: $settings.profile) {
            Text("Auto").tag("auto")
            ForEach(ProfileID.allCases, id: \.rawValue) { Text(Profiles.profile($0).short).tag($0.rawValue) }
          }
          let p = currentProfile()
          VStack(alignment: .leading, spacing: 8) {
            let app = session.frontApp.name.replacingOccurrences(of: "Adobe ", with: "")
            Text(settings.profile == "auto" && !app.isEmpty && app != p.name ? "\(app) → \(p.name)" : p.name).font(.subheadline.bold())
            ForEach(p.descriptions, id: \.0) { row in
              HStack(alignment: .top) {
                Text(row.0).font(.caption.bold()).frame(width: 72, alignment: .leading)
                Text(row.1).font(.caption).foregroundStyle(.secondary)
              }
            }
          }.padding(.vertical, 4)
          LabeledContent("Tracking speed") { Slider(value: $settings.pointerSpeed, in: 0.4...2.6) }
          LabeledContent("Scroll speed") { Slider(value: $settings.scrollSpeed, in: 0.4...2.6) }
          Toggle("Natural scrolling", isOn: $settings.natural)
          Toggle("Full trackpad when opened flat", isOn: $settings.trackpadWhenFlat)
          Toggle("Landscape: use screen as trackpad", isOn: $settings.landscapeTrackpad)
        }

        Section("Keyboard") {
          Toggle("Haptics", isOn: $settings.haptics)
          Toggle("Key click sound", isOn: $settings.keyClicks)
        }

        Section("Stream") {
          Picker("Quality", selection: $settings.quality) { ForEach(Quality.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
          Toggle("Sound", isOn: $settings.sound)
          Text(session.stats).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        }

        Section("Mac") {
          LabeledContent("Paired with", value: session.hostName)
          Button("Forget This Mac", role: .destructive) { confirmForget = true }
        }

        Section {
          Text("On the screen itself: tap to click, long-press to right-click, drag to select or move, two fingers to scroll, pinch to zoom the view. Three fingers work the same as on the trackpad. Auto picks the profile from the app in front on your Mac.").font(.footnote).foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Clamshell")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
      .confirmationDialog("Forget this Mac? You'll need to scan its code again.", isPresented: $confirmForget, titleVisibility: .visible) {
        Button("Forget This Mac", role: .destructive, action: onForget)
      }
    }
  }
}

private struct MiniLaptop: View {
  let theme: Theme
  var body: some View {
    VStack(spacing: 0) {
      RoundedRectangle(cornerRadius: 4).fill(Color(theme.bezel))
        .overlay(RoundedRectangle(cornerRadius: 2).fill(LinearGradient(colors: [.blue, .purple, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)).padding(3))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(theme.lid), lineWidth: 2))
        .frame(width: 60, height: 30)
      VStack(spacing: 2) {
        RoundedRectangle(cornerRadius: 1).fill(Color(theme.key)).overlay(RoundedRectangle(cornerRadius: 1).stroke(Color(theme.well), lineWidth: 1)).frame(height: 11)
        RoundedRectangle(cornerRadius: 2).fill(Color(theme.pad)).frame(width: 26, height: 9)
      }
      .padding(3).frame(width: 78, height: 30)
      .background(LinearGradient(colors: [Color(theme.deckTop), Color(theme.deckBottom)], startPoint: .top, endPoint: .bottom), in: UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6))
    }
  }
}
