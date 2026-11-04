import ClamshellCore
import SwiftUI

@main
struct ClamshellHostApp: App {
  @StateObject private var model = HostModel()

  var body: some Scene {
    Window("Clamshell", id: "main") {
      HostView().environmentObject(model)
    }
    .windowResizability(.contentSize)

    MenuBarExtra {
      Text(model.phoneName.map { "Streaming to \($0)" } ?? "Waiting for your iPhone")
      Divider()
      OpenWindowButton()
      Button("Quit Clamshell") { NSApp.terminate(nil) }
    } label: {
      Image(systemName: model.phoneName == nil ? "macbook" : "macbook.and.iphone")
    }
  }
}

private struct OpenWindowButton: View {
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    Button("Show Pairing Code…") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
  }
}

struct HostView: View {
  @EnvironmentObject var model: HostModel

  var body: some View {
    HStack(alignment: .top, spacing: 24) {
      VStack(spacing: 10) {
        if let img = model.pairingImage {
          Image(nsImage: img).interpolation(.none).resizable().frame(width: 240, height: 240)
            .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 14))
        }
        Text("Scan with your iPhone").font(.headline)
        Text("Open the camera or the Clamshell app and point it at this code. Only needed once.")
          .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 250)
      }

      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 8) {
          Circle().fill(model.phoneName == nil ? Color.orange : Color.green).frame(width: 10, height: 10)
          Text(model.phoneName.map { "Streaming to \($0)" } ?? "Waiting for your iPhone").font(.title3.weight(.semibold))
        }
        if model.phoneName != nil { Text(model.stats).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
        if let p = model.problem { Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
        if model.isDemo {
          Label("Demo mode: nothing here touches your real Mac", systemImage: "theatermasks").font(.callout).foregroundStyle(.secondary)
          Picker("Simulated front app", selection: $model.demoApp) {
            Text("Finder").tag("com.apple.finder")
            Text("Premiere Pro").tag("com.adobe.PremierePro.26")
            Text("Final Cut Pro").tag("com.apple.FinalCut")
          }
        }

        GroupBox("Permissions") {
          VStack(alignment: .leading, spacing: 8) {
            PermissionRow(title: "Screen Recording", detail: "Lets your iPhone see this screen", granted: model.hasScreenAccess, action: model.requestScreenAccess)
            PermissionRow(title: "Accessibility", detail: "Lets your iPhone move the pointer and type", granted: model.hasInputAccess, action: model.requestInputAccess)
          }.padding(4)
        }

        Picker("Screen", selection: Binding(get: { model.activeDisplay }, set: { model.select(display: $0) })) {
          ForEach(model.displays) { d in Text("\(d.name) (\(d.width)×\(d.height))").tag(d.id) }
        }

        VStack(alignment: .leading, spacing: 4) {
          Text("Addresses").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          ForEach(model.addresses, id: \.self) { a in Text(a).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
        }

        Button("Unpair All Phones", role: .destructive, action: model.unpairAll).disabled(model.isDemo).buttonStyle(.link).font(.caption)
      }.frame(width: 360, alignment: .leading)
    }
    .padding(24)
  }
}

private struct PermissionRow: View {
  let title: String, detail: String, granted: Bool, action: () -> Void
  var body: some View {
    HStack {
      Image(systemName: granted ? "checkmark.circle.fill" : "circle").foregroundStyle(granted ? .green : .secondary)
      VStack(alignment: .leading) { Text(title); Text(detail).font(.caption).foregroundStyle(.secondary) }
      Spacer()
      if !granted { Button("Allow…", action: action) }
    }
  }
}
