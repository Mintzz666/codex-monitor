import AppKit
import CodexUsageShared
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
  private let viewModel: UsageViewModel
  private let statusItem: NSStatusItem
  private let popover = NSPopover()
  private var cancellables = Set<AnyCancellable>()

  init(viewModel: UsageViewModel) {
    self.viewModel = viewModel
    statusItem = NSStatusBar.system.statusItem(
      withLength: NSStatusItem.variableLength
    )
    super.init()

    configurePopover()
    configureStatusButton()
    observeUsage()
    updateStatusButton()
  }

  deinit {
    NSStatusBar.system.removeStatusItem(statusItem)
  }

  private func configurePopover() {
    let content = UsageMenuView(
      viewModel: viewModel,
      language: Binding(
        get: { self.viewModel.displayLanguage },
        set: { self.viewModel.setDisplayLanguage($0) }
      )
    )
    let availableHeight =
      statusItem.button?.window?.screen?.visibleFrame.height
      ?? NSScreen.main?.visibleFrame.height ?? 900
    let height = min(780, max(240, availableHeight - 40))
    let scrollableContent = ScrollView(.vertical) {
      content.fixedSize(horizontal: false, vertical: true)
    }
    .frame(width: 366, height: height)
    popover.contentViewController = NSHostingController(rootView: scrollableContent)
    popover.contentSize = NSSize(width: 366, height: height)
    popover.behavior = .transient
    popover.animates = true
  }

  private func configureStatusButton() {
    guard let button = statusItem.button else { return }
    button.target = self
    button.action = #selector(togglePopover)
    button.sendAction(on: [.leftMouseUp])
    button.image = Self.statusImage
    button.imagePosition = .imageLeading
    button.imageScaling = .scaleNone
    button.font = .monospacedDigitSystemFont(
      ofSize: NSFont.systemFontSize,
      weight: .regular
    )
  }

  private func observeUsage() {
    Publishers.CombineLatest4(
      viewModel.$snapshot,
      viewModel.$isRefreshing,
      viewModel.$displayLanguage,
      viewModel.$errorMessage
    )
    .receive(on: RunLoop.main)
    .sink { [weak self] _, _, _, _ in
      self?.updateStatusButton()
    }
    .store(in: &cancellables)
  }

  private func updateStatusButton() {
    guard let button = statusItem.button else { return }
    button.title = " \(viewModel.menuBarText)"
    let language = viewModel.displayLanguage
    let status =
      viewModel.errorDisplayText(for: language)
      ?? viewModel.lastUpdatedDisplayText(for: language)
    button.toolTip = "\(language.text(.menuBarAccessibility)) · \(viewModel.menuBarText)\n\(status)"
    button.appearsDisabled = viewModel.errorMessage != nil
    button.setAccessibilityLabel(
      viewModel.displayLanguage.text(.menuBarAccessibility)
    )
    button.setAccessibilityValue(viewModel.menuBarText)
  }

  @objc private func togglePopover() {
    guard let button = statusItem.button else { return }
    if popover.isShown {
      popover.performClose(nil)
    } else {
      configurePopover()
      viewModel.refreshLaunchAtLoginStatus()
      Task { await viewModel.refreshIfStale() }
      popover.show(
        relativeTo: button.bounds,
        of: button,
        preferredEdge: .minY
      )
      popover.contentViewController?.view.window?.makeKey()
    }
  }

  private static let statusImage: NSImage = {
    let image =
      Bundle.main.url(
        forResource: "OfficialCodexMenuTemplate",
        withExtension: "png"
      ).flatMap(NSImage.init(contentsOf:))
      ?? NSImage(
        systemSymbolName: "terminal",
        accessibilityDescription: nil
      )
      ?? NSImage()
    image.size = NSSize(width: 16, height: 16)
    image.isTemplate = true
    return image
  }()
}
