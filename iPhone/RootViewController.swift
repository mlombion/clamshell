// Portrait: the Mac's screen above the fold, keyboard and trackpad below. Landscape: all screen.
import AudioToolbox
import ClamshellCore
import Combine
import SwiftUI
import UIKit

final class RootViewController: UIViewController {
  let settings = AppSettings()
  let session = PhoneSession()
  private let keyboardEngine = KeyboardEngine()
  private lazy var context = GestureContext(keyboard: keyboardEngine)
  private lazy var trackpad = TrackpadEngine(context: context)
  private lazy var screenTrackpad = TrackpadEngine(context: context)
  private lazy var direct = DirectTouchEngine(context: context)

  private let lid = UIView(), bezel = UIView(), screen = TouchSurface(), video = VideoSurface()
  private let notch = UIButton(type: .custom), cameraDot = UIView()
  private let overlay = UIView(), overlayTitle = UILabel(), overlayText = UILabel(), spinner = UIActivityIndicatorView(style: .medium)
  private let deck = UIView(), deckGradient = CAGradientLayer(), deckEdge = UIView(), well = UIView()
  private lazy var keyboardView = KeyboardView(engine: keyboardEngine)
  private let editBar = UIView()
  private var editButtons: [EditBarButton] = []
  private var editSeparators: [Int] = []
  private let pad = TouchSurface(), grilleL = GrilleView(), grilleR = GrilleView()
  private let padLeft = TouchSurface(), padRight = TouchSurface()
  private let toast = UILabel()
  private var toastTimer: Timer?

  private enum DeckMode { case keyboard, trackpad }
  private var deckMode = DeckMode.keyboard
  private var landscapeKeyboard = false
  private var hingeIsFlat = false
  private var displayLink: CADisplayLink?
  private var bag = Set<AnyCancellable>()
  private var theme: Theme { Theme.named(settings.theme) }
  private var pairingController: UIViewController?

  private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
  private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)
  private let detentHaptic = UISelectionFeedbackGenerator()

  override var prefersStatusBarHidden: Bool { true }
  override var prefersHomeIndicatorAutoHidden: Bool { true }
  override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

  override func viewDidLoad() {
    super.viewDidLoad()
    buildViews()
    wireEngines()
    observe()
    observeHinge()
    applyTheme()
    session.surface = video
    if let p = PairingKeychain.load() { session.use(p) }
    refreshOverlay()
    lightHaptic.prepare(); detentHaptic.prepare()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    updatePairingScreen()
    let link = CADisplayLink(target: self, selector: #selector(tick))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  @objc private func tick() {
    let now = CACurrentMediaTime()
    keyboardEngine.tick(now: now)
    trackpad.tick(now: now)
    screenTrackpad.tick(now: now)
    direct.tick(now: now)
    context.scroller.tick(now: now)
  }

  // MARK: pieces

  private func buildViews() {
    view.addSubview(lid)
    lid.addSubview(bezel)
    bezel.addSubview(screen)
    screen.clipsToBounds = true
    screen.addSubview(video)
    screen.addSubview(overlay)
    bezel.addSubview(notch)
    notch.addSubview(cameraDot)
    cameraDot.isUserInteractionEnabled = false
    cameraDot.layer.cornerRadius = 3.5
    notch.showsMenuAsPrimaryAction = true
    notch.menu = makeMenu()

    overlay.backgroundColor = UIColor(white: 0.04, alpha: 1)
    overlay.isUserInteractionEnabled = false
    overlayTitle.font = .systemFont(ofSize: 17, weight: .semibold); overlayTitle.textColor = .white; overlayTitle.textAlignment = .center
    overlayText.font = .systemFont(ofSize: 13); overlayText.textColor = .lightGray; overlayText.textAlignment = .center; overlayText.numberOfLines = 0
    spinner.color = .white; spinner.startAnimating()
    [overlayTitle, overlayText, spinner].forEach(overlay.addSubview)

    view.addSubview(deck)
    deck.layer.addSublayer(deckGradient)
    deck.addSubview(deckEdge)
    deck.addSubview(well)
    well.addSubview(keyboardView)
    keyboardView.onPress = { [weak self] in self?.keyFeedback() }
    keyboardEngine.onMenu = { [weak self] in self?.showSettings() }
    deck.addSubview(editBar)
    [grilleL, grilleR, pad, padLeft, padRight].forEach(deck.addSubview)
    pad.layer.borderWidth = 0.5

    toast.font = .systemFont(ofSize: 14, weight: .semibold); toast.textColor = .white; toast.textAlignment = .center
    toast.backgroundColor = UIColor(white: 0.1, alpha: 0.85); toast.layer.cornerRadius = 13; toast.clipsToBounds = true; toast.alpha = 0
    view.addSubview(toast)
    toast.isUserInteractionEnabled = false
  }

  private func wireEngines() {
    keyboardEngine.send = { [weak self] e in self?.session.link.send(e, reliable: true) }
    context.send = { [weak self] e, reliable in self?.session.link.send(e, reliable: reliable) }
    context.feedback = { [weak self] in self?.gestureFeedback($0) }
    syncContext()

    pad.began = { [weak self] t, s in self?.trackpad.began(t, t: s) }
    pad.moved = { [weak self] t, s in self?.trackpad.moved(t, t: s) }
    pad.ended = { [weak self] t, s in self?.trackpad.ended(t, t: s) }

    // The picture: direct touch, or a trackpad if chosen for landscape. Decided per gesture, so rotating mid-touch can't confuse it.
    screen.began = { [weak self] t, s in
      guard let self else { return }
      if self.screenIsTrackpad { self.screenTrackpad.began(t, t: s) } else { self.direct.began(t, t: s) }
    }
    screen.moved = { [weak self] t, s in
      guard let self else { return }
      if self.screenIsTrackpad { self.screenTrackpad.moved(t, t: s) } else { self.direct.moved(t, t: s) }
    }
    screen.ended = { [weak self] t, s in
      guard let self else { return }
      if self.screenIsTrackpad { self.screenTrackpad.ended(t, t: s) } else { self.direct.ended(t, t: s) }
    }
    direct.mapToDisplay = { [weak self] x, y in self?.mapToDisplay(x, y) }
    direct.onViewChanged = { [weak self] v in self?.applyViewTransform(v) }

    padLeft.began = { [weak self] _, _ in self?.padButton(0, down: true) }
    padLeft.ended = { [weak self] _, _ in self?.padButton(0, down: false) }
    padRight.began = { [weak self] _, _ in self?.padButton(1, down: true) }
    padRight.ended = { [weak self] _, _ in self?.padButton(1, down: false) }
  }

  private var screenIsTrackpad: Bool { isLandscape && settings.landscapeTrackpad }
  private var isLandscape: Bool { view.bounds.width > view.bounds.height }

  private func padButton(_ b: UInt8, down: Bool) {
    keyboardEngine.markModifiersUsed()
    session.link.send(.button(index: b, down: down), reliable: true)
    if down { lightHaptic.impactOccurred() } else { keyboardEngine.releaseLatched() }
  }

  private func syncContext() {
    context.pointerSpeed = settings.pointerSpeed
    context.scrollSpeed = settings.scrollSpeed
    context.naturalScrolling = settings.natural
    let id: ProfileID
    if let fixed = ProfileID(rawValue: settings.profile) { id = fixed } else { id = Profiles.id(forBundleID: session.frontApp.id) }
    if context.profile.id != id {
      context.profile = Profiles.profile(id)
      show(toast: "\(context.profile.short) gestures")
    }
    rebuildEditBar()
  }

  private func observe() {
    settings.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
      DispatchQueue.main.async { self?.settingsChanged() }
    }.store(in: &bag)
    session.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
      DispatchQueue.main.async { self?.sessionChanged() }
    }.store(in: &bag)
    NotificationCenter.default.addObserver(forName: .pairingLink, object: nil, queue: .main) { [weak self] n in
      if let p = n.object as? PairingInfo { self?.pair(p) }
    }
  }

  private var lastQuality: Quality?, lastTheme = "", lastSound: Bool?, lastState: PhoneSession.State?

  private func settingsChanged() {
    syncContext()
    if settings.theme != lastTheme { applyTheme() }
    if settings.quality != lastQuality { lastQuality = settings.quality; session.send(.setQuality(settings.quality)) }
    if settings.sound != lastSound { lastSound = settings.sound; session.audio.setMuted(!settings.sound) }
    applyHinge()
  }

  private func sessionChanged() {
    syncContext()
    refreshOverlay()
    updatePairingScreen()
    if session.state != lastState {
      if session.state == .opening {
        session.send(.setQuality(settings.quality))
        session.audio.setMuted(!settings.sound)
      }
      lastState = session.state
    }
    UIApplication.shared.isIdleTimerDisabled = session.state == .live || session.state == .opening
    view.setNeedsLayout()
  }

  func pair(_ p: PairingInfo) {
    PairingKeychain.save(p)
    session.use(p)
    updatePairingScreen()
  }

  func resumeSession() { if session.pairing != nil { session.resume() } }
  func suspendSession() {
    keyboardEngine.reset()
    session.suspend()
  }

  // MARK: pairing and settings screens

  private func updatePairingScreen() {
    let needsPairing = session.pairing == nil
    if needsPairing, pairingController == nil, view.window != nil, presentedViewController == nil {
      let vc = UIHostingController(rootView: PairingScreen { [weak self] in self?.pair($0) })
      vc.modalPresentationStyle = .fullScreen
      pairingController = vc
      present(vc, animated: false)
    } else if !needsPairing, let vc = pairingController {
      pairingController = nil
      vc.dismiss(animated: true)
    }
  }

  private func showSettings() {
    guard presentedViewController == nil else { return }
    let vc = UIHostingController(rootView: SettingsScreen(settings: settings, session: session, currentProfile: { [weak self] in self?.context.profile ?? Profiles.mac }, onForget: { [weak self] in
      PairingKeychain.clear()
      self?.session.forget()
      self?.dismiss(animated: true) { self?.updatePairingScreen() }
    }))
    if let sheet = vc.sheetPresentationController { sheet.detents = [.large()]; sheet.prefersGrabberVisible = true }
    present(vc, animated: true)
  }

  // MARK: notch menu

  private func makeMenu() -> UIMenu {
    UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
      guard let self else { return done([]) }
      done(self.menuItems())
    }])
  }

  private func menuItems() -> [UIMenuElement] {
    var items: [UIMenuElement] = []
    let status = UIAction(title: session.state == .live ? "\(session.hostName) connected" : "Not connected", subtitle: session.stats, attributes: .disabled) { _ in }
    items.append(UIMenu(options: .displayInline, children: [status]))

    if isLandscape {
      items.append(UIAction(title: landscapeKeyboard ? "Hide Keyboard" : "Show Keyboard", image: UIImage(systemName: "keyboard")) { [weak self] _ in
        self?.landscapeKeyboard.toggle(); self?.layoutForMode(animated: true)
      })
      items.append(UIAction(title: settings.landscapeTrackpad ? "Touch the Screen" : "Use Screen as Trackpad", image: UIImage(systemName: settings.landscapeTrackpad ? "hand.point.up.left" : "rectangle.and.hand.point.up.left")) { [weak self] _ in self?.settings.landscapeTrackpad.toggle() })
      if direct.view.scale > 1 {
        items.append(UIAction(title: "Reset Zoom", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { [weak self] _ in self?.direct.resetView() })
      }
    } else {
      items.append(UIAction(title: deckMode == .keyboard ? "Full Trackpad" : "Show Keyboard", image: UIImage(systemName: deckMode == .keyboard ? "rectangle.inset.filled" : "keyboard")) { [weak self] _ in
        guard let self else { return }
        self.deckMode = self.deckMode == .keyboard ? .trackpad : .keyboard
        self.layoutForMode(animated: true)
      })
    }

    let profiles: [UIAction] = [("auto", "Auto")].map { p in
      UIAction(title: session.frontApp.name.isEmpty ? p.1 : "\(p.1) (\(session.frontApp.name))", state: settings.profile == p.0 ? .on : .off) { [weak self] _ in self?.settings.profile = p.0 }
    } + ProfileID.allCases.map { id in
      UIAction(title: Profiles.profile(id).short, state: settings.profile == id.rawValue ? .on : .off) { [weak self] _ in self?.settings.profile = id.rawValue }
    }
    items.append(UIMenu(title: "Gestures", subtitle: context.profile.short, image: UIImage(systemName: "hand.draw"), children: profiles))

    items.append(UIMenu(title: "Quality", subtitle: settings.quality.title, image: UIImage(systemName: "gauge.with.dots.needle.67percent"), children: Quality.allCases.map { q in
      UIAction(title: q.title, state: settings.quality == q ? .on : .off) { [weak self] _ in self?.settings.quality = q }
    }))
    if session.displays.count > 1 {
      items.append(UIMenu(title: "Screen", image: UIImage(systemName: "display.2"), children: session.displays.map { d in
        UIAction(title: d.name, subtitle: "\(d.width)×\(d.height)", state: session.activeDisplay == d.id ? .on : .off) { [weak self] _ in self?.session.send(.selectDisplay(d.id)) }
      }))
    }
    items.append(UIAction(title: settings.sound ? "Mute Sound" : "Play Sound", image: UIImage(systemName: settings.sound ? "speaker.slash" : "speaker.wave.2")) { [weak self] _ in self?.settings.sound.toggle() })
    items.append(UIAction(title: "Themes & Settings", image: UIImage(systemName: "paintpalette")) { [weak self] _ in self?.showSettings() })
    return items
  }

  // MARK: fold

  private func observeHinge() {
    guard #available(iOS 27.1, *) else { return }
    let interaction = UIHingeInteraction { [weak self] _, update in
      self?.hingeIsFlat = update.hinge?.status == .fullyOpen
      self?.applyHinge()
    }
    view.addInteraction(interaction)
  }

  private var lastHingeFlat: Bool?
  private func applyHinge() {
    guard hingeIsFlat != lastHingeFlat else { return }
    lastHingeFlat = hingeIsFlat
    deckMode = hingeIsFlat && settings.trackpadWhenFlat ? .trackpad : .keyboard
    layoutForMode(animated: true)
  }

  // MARK: feedback

  private func keyFeedback() {
    if settings.haptics { lightHaptic.impactOccurred(intensity: 0.7) }
    if settings.keyClicks { AudioServicesPlaySystemSound(1104) }
  }

  private func gestureFeedback(_ f: GestureFeedback) {
    DispatchQueue.main.async { [self] in
      switch f {
      case .tap: if settings.haptics { lightHaptic.impactOccurred() }
      case .detent: if settings.haptics { detentHaptic.selectionChanged() }
      case .dragStarted: if settings.haptics { mediumHaptic.impactOccurred() }; pad.backgroundColor = theme.padDown
      case .dragEnded: pad.backgroundColor = theme.pad
      case .toast(let s): show(toast: s)
      }
    }
  }

  private func show(toast text: String) {
    toast.text = text
    view.bringSubviewToFront(toast)
    let w = (text as NSString).size(withAttributes: [.font: toast.font!]).width + 32
    toast.frame = CGRect(x: (view.bounds.width - w) / 2, y: view.bounds.height * 0.22, width: w, height: 34)
    UIView.animate(withDuration: 0.15) { self.toast.alpha = 1 }
    toastTimer?.invalidate()
    toastTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in UIView.animate(withDuration: 0.2) { self?.toast.alpha = 0 } }
  }

  // MARK: look

  private func applyTheme() {
    let t = theme
    lastTheme = t.id
    view.backgroundColor = t.outer
    lid.backgroundColor = t.lid
    bezel.backgroundColor = t.bezel
    bezel.layer.cornerRadius = t.screenRadius + t.bezelWidth * 0.6
    bezel.layer.cornerCurve = .continuous
    screen.layer.cornerRadius = t.screenRadius
    screen.layer.borderWidth = t.frame; screen.layer.borderColor = t.frameColor.cgColor
    notch.backgroundColor = t.bezel
    notch.layer.cornerRadius = 10
    notch.layer.maskedCorners = t.vintage ? [] : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    deckGradient.colors = [t.deckTop.cgColor, t.deckBottom.cgColor]
    deckEdge.backgroundColor = t.deckEdge
    well.backgroundColor = t.well
    well.layer.cornerRadius = t.keyRadius + 3
    well.layer.cornerCurve = .continuous
    keyboardView.apply(t)
    pad.backgroundColor = t.pad
    pad.layer.cornerRadius = t.padRadius
    pad.layer.borderColor = UIColor(white: t.vintage ? 0 : 1, alpha: 0.1).cgColor
    [padLeft, padRight].forEach { $0.backgroundColor = t.button; $0.layer.cornerRadius = 8; $0.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] }
    grilleL.color = t.grille; grilleR.color = t.grille
    grilleL.rounded = t.id != "ivory"; grilleR.rounded = t.id != "ivory"
    editButtons.forEach { $0.apply(t) }
    view.setNeedsLayout()
    refreshDot()
  }

  private func refreshDot() {
    switch session.state {
    case .live: cameraDot.backgroundColor = .systemGreen
    case .rejected, .unpaired: cameraDot.backgroundColor = .systemRed
    default: cameraDot.backgroundColor = .systemOrange
    }
  }

  private func refreshOverlay() {
    refreshDot()
    overlay.isHidden = session.state == .live
    spinner.isHidden = session.state == .rejected || session.problem != nil
    switch session.state {
    case .unpaired: overlayTitle.text = "Not paired"; overlayText.text = "Scan the code shown by Clamshell Host on your Mac."
    case .rejected: overlayTitle.text = "Pairing no longer valid"; overlayText.text = "Your Mac has a new pairing code. Open Settings, choose Forget This Mac, then scan again."
    case .connecting: overlayTitle.text = "Looking for \(session.hostName)…"; overlayText.text = "Make sure Clamshell Host is open on your Mac."
    case .opening, .live: overlayTitle.text = "Opening the stream…"; overlayText.text = session.problem ?? ""
    }
    if let p = session.problem, session.state != .live { overlayText.text = p }
    if session.state == .opening, let p = session.problem { overlayTitle.text = "Waiting on your Mac"; overlayText.text = p }
  }

  private func rebuildEditBar() {
    let items = context.profile.bar
    guard items.map(\.label) != editButtons.map(\.item.label) else { return }
    editButtons.forEach { $0.removeFromSuperview() }
    editSeparators = []
    editButtons = items.enumerated().map { i, item in
      if item.startsGroup { editSeparators.append(i) }
      let b = EditBarButton(item)
      b.apply(theme)
      b.onDown = { [weak self] item in self?.editKey(item, down: true) }
      b.onUp = { [weak self] item in self?.editKey(item, down: false) }
      editBar.addSubview(b)
      return b
    }
    view.setNeedsLayout()
  }

  private var editHeldModifiers: [String: [UInt16]] = [:]
  private func editKey(_ item: EditBarItem, down: Bool) {
    guard let key = item.keys.last else { return }
    if down {
      let mods = item.keys.dropLast().filter { keyboardEngine.state(of: $0) == nil }
      editHeldModifiers[item.id] = Array(mods)
      mods.forEach { session.link.send(.key(code: $0, down: true, isRepeat: false), reliable: true) }
      session.link.send(.key(code: key, down: true, isRepeat: false), reliable: true)
      keyFeedback()
    } else {
      session.link.send(.key(code: key, down: false, isRepeat: false), reliable: true)
      (editHeldModifiers.removeValue(forKey: item.id) ?? []).reversed().forEach { session.link.send(.key(code: $0, down: false, isRepeat: false), reliable: true) }
    }
  }

  // MARK: layout

  override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
    super.viewWillTransition(to: size, with: coordinator)
    direct.resetView()
    setNeedsUpdateOfHomeIndicatorAutoHidden()
    setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
  }

  private func layoutForMode(animated: Bool) {
    view.setNeedsLayout()
    if animated { UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) { self.view.layoutIfNeeded() } }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let B = view.bounds, safe = view.safeAreaInsets, t = theme
    let landscape = isLandscape
    let showKeyboardLandscape = landscape && landscapeKeyboard

    // The fold runs across the middle of the inner display.
    let lidHeight = landscape ? (showKeyboardLandscape ? B.height * 0.5 : B.height) : B.height * 0.5
    lid.frame = CGRect(x: 0, y: 0, width: B.width, height: lidHeight)
    if landscape {
      bezel.frame = lid.bounds
      bezel.layer.cornerRadius = 0; bezel.backgroundColor = .black; lid.backgroundColor = .black
      screen.frame = bezel.bounds
      screen.layer.cornerRadius = 0; screen.layer.borderWidth = 0
      notch.frame = CGRect(x: (B.width - 62) / 2, y: max(4, safe.top), width: 62, height: 22)
      notch.backgroundColor = UIColor(white: 0, alpha: 0.42)
      notch.layer.cornerRadius = 11
      notch.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    } else {
      lid.backgroundColor = t.lid
      let rim = t.rim
      bezel.frame = CGRect(x: rim, y: safe.top + rim, width: B.width - rim * 2, height: lidHeight - safe.top - rim * 2)
      bezel.backgroundColor = t.bezel
      bezel.layer.cornerRadius = t.screenRadius + t.bezelWidth * 0.6
      screen.frame = CGRect(x: t.bezelWidth, y: t.bezelTop, width: bezel.bounds.width - t.bezelWidth * 2, height: bezel.bounds.height - t.bezelTop - t.bezelWidth)
      screen.layer.cornerRadius = t.screenRadius; screen.layer.borderWidth = t.frame
      let w = max(84, bezel.bounds.width * 0.2), dip: CGFloat = t.vintage ? 0 : 10
      notch.frame = CGRect(x: (bezel.bounds.width - w) / 2, y: 0, width: w, height: t.bezelTop + dip)
      notch.backgroundColor = t.bezel
      notch.layer.cornerRadius = 10
      notch.layer.maskedCorners = t.vintage ? [] : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    }
    cameraDot.frame = CGRect(x: notch.bounds.midX - 3.5, y: notch.bounds.midY - 3.5, width: 7, height: 7)
    video.bounds = CGRect(origin: .zero, size: screen.bounds.size)
    video.center = CGPoint(x: screen.bounds.midX, y: screen.bounds.midY)
    applyViewTransform(direct.view)
    direct.viewportSize = (Double(screen.bounds.width), Double(screen.bounds.height))
    overlay.frame = screen.bounds
    let cy = overlay.bounds.midY
    spinner.center = CGPoint(x: overlay.bounds.midX, y: cy - 34)
    overlayTitle.frame = CGRect(x: 16, y: cy - 16, width: overlay.bounds.width - 32, height: 24)
    overlayText.frame = CGRect(x: 24, y: cy + 10, width: overlay.bounds.width - 48, height: 54)

    // Deck
    deck.isHidden = landscape && !showKeyboardLandscape
    deck.frame = CGRect(x: 0, y: lidHeight, width: B.width, height: B.height - lidHeight)
    deckGradient.frame = deck.bounds
    deckEdge.frame = CGRect(x: 0, y: 0, width: B.width, height: 1)
    // In portrait the sensors sit in the lid, so the deck can use the full width.
    let side = landscape ? max(B.width * 0.03, max(safe.left, safe.right)) : B.width * 0.03
    let bottom = max(10, safe.bottom)
    var y: CGFloat = max(8, deck.bounds.height * 0.03)
    let available = deck.bounds.height - y - bottom

    if landscape {
      well.isHidden = false
      [pad, padLeft, padRight, grilleL, grilleR, editBar].forEach { $0.isHidden = true }
      let h = available, w = min(deck.bounds.width - side * 2, h * KeyboardView.aspect)
      well.frame = CGRect(x: (deck.bounds.width - w) / 2, y: y, width: w, height: h)
      keyboardView.frame = well.bounds.insetBy(dx: w * 0.009, dy: w * 0.009)
      return
    }

    let showKeyboard = deckMode == .keyboard
    let width = B.width - side * 2
    let wellWidth = t.vintage ? width * 0.94 : width
    well.isHidden = !showKeyboard
    if showKeyboard {
      let inset = wellWidth * 0.009
      let kbHeight = min((wellWidth - inset * 2) / KeyboardView.aspect, available * 0.62)
      well.frame = CGRect(x: (B.width - wellWidth) / 2, y: y, width: wellWidth, height: kbHeight + inset * 2)
      keyboardView.frame = well.bounds.insetBy(dx: inset, dy: inset)
      y = well.frame.maxY + available * 0.025
    }

    editBar.isHidden = editButtons.isEmpty
    if !editButtons.isEmpty {
      let h = min(46, max(32, width * 0.08))
      editBar.frame = CGRect(x: side, y: y, width: width, height: h)
      let groupGap: CGFloat = 6, gap: CGFloat = 4
      let total = CGFloat(editButtons.count - 1) * gap + CGFloat(editSeparators.count) * groupGap
      let bw = (width - total) / CGFloat(editButtons.count)
      var x: CGFloat = 0
      for (i, b) in editButtons.enumerated() {
        if editSeparators.contains(i) { x += groupGap }
        b.frame = CGRect(x: x, y: 0, width: bw, height: h)
        x += bw + gap
      }
      y = editBar.frame.maxY + available * 0.025
    }

    let padAreaHeight = deck.bounds.height - y - bottom
    pad.isHidden = false
    if !showKeyboard {
      pad.frame = CGRect(x: side, y: y, width: width, height: padAreaHeight)
      [padLeft, padRight, grilleL, grilleR].forEach { $0.isHidden = true }
    } else if t.vintage {
      let w = width * 0.36, buttonH = max(22, padAreaHeight * 0.16)
      pad.frame = CGRect(x: (B.width - w) / 2, y: y, width: w, height: padAreaHeight - buttonH - 4)
      padLeft.isHidden = false; padRight.isHidden = t.singleButton
      let by = pad.frame.maxY + 4
      if t.singleButton { padLeft.frame = CGRect(x: pad.frame.minX, y: by, width: w, height: buttonH) }
      else {
        padLeft.frame = CGRect(x: pad.frame.minX, y: by, width: w / 2 - 2, height: buttonH)
        padRight.frame = CGRect(x: pad.frame.midX + 2, y: by, width: w / 2 - 2, height: buttonH)
      }
      let g = min(width * 0.16, padAreaHeight * 0.75)
      grilleL.isHidden = false; grilleR.isHidden = false
      grilleL.frame = CGRect(x: side + width * 0.08, y: y + (padAreaHeight - g) / 2, width: g, height: g)
      grilleR.frame = CGRect(x: B.width - side - width * 0.08 - g, y: y + (padAreaHeight - g) / 2, width: g, height: g)
    } else {
      let w = width * 0.6
      pad.frame = CGRect(x: (B.width - w) / 2, y: y, width: w, height: padAreaHeight)
      [padLeft, padRight, grilleL, grilleR].forEach { $0.isHidden = true }
    }
    view.bringSubviewToFront(toast)
  }

  private func applyViewTransform(_ v: ViewTransform) {
    // Zoom in the viewport's top-left coordinate space, which is what the gesture engine works in.
    let w = screen.bounds.width, h = screen.bounds.height, s = CGFloat(v.scale)
    let dx = CGFloat(v.x) + (s - 1) * w / 2, dy = CGFloat(v.y) + (s - 1) * h / 2
    video.transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: s, y: s)
  }

  private func mapToDisplay(_ x: Double, _ y: Double) -> (Float, Float)? {
    guard let s = session.stream, s.width > 0, s.height > 0 else { return nil }
    let v = direct.view, W = Double(screen.bounds.width), H = Double(screen.bounds.height)
    let px = (x - v.x) / v.scale, py = (y - v.y) / v.scale
    let fit = min(W / Double(s.width), H / Double(s.height))
    let cw = Double(s.width) * fit, ch = Double(s.height) * fit
    let nx = (px - (W - cw) / 2) / cw, ny = (py - (H - ch) / 2) / ch
    guard (0...1).contains(nx), (0...1).contains(ny) else { return nil }
    return (Float(nx), Float(ny))
  }
}

extension Notification.Name { static let pairingLink = Notification.Name("clamshell.pairingLink") }
