import AppKit
import CodexUsageShared
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
  private let viewModel: UsageViewModel
  private let badgeIntegrationModel: BadgeIntegrationViewModel
  private let statusItem: NSStatusItem
  private let popover = NSPopover()
  private var cancellables = Set<AnyCancellable>()

  init(viewModel: UsageViewModel, badgeIntegrationModel: BadgeIntegrationViewModel) {
    self.viewModel = viewModel
    self.badgeIntegrationModel = badgeIntegrationModel
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
    let scrollableContent = ScrollView(.vertical) {
      menuContent.fixedSize(horizontal: false, vertical: true)
    }
    .frame(width: UsageMenuView.width)
    let controller = NSHostingController(rootView: scrollableContent)
    controller.sizingOptions = []
    popover.contentViewController = controller
    resizePopoverToFitContent()
    popover.behavior = .transient
    popover.animates = true
  }

  private var menuContent: some View {
    UsageMenuView(
      viewModel: viewModel,
      badgeIntegrationModel: badgeIntegrationModel,
      language: Binding(
        get: { self.viewModel.displayLanguage },
        set: { self.viewModel.setDisplayLanguage($0) }
      )
    )
  }

  private func resizePopoverToFitContent() {
    let measurement = NSHostingController(
      rootView: menuContent.fixedSize(horizontal: false, vertical: true)
    )
    let availableHeight =
      statusItem.button?.window?.screen?.visibleFrame.height
      ?? NSScreen.main?.visibleFrame.height ?? 900
    let contentHeight = ceil(measurement.view.fittingSize.height)
    let height = min(contentHeight, max(240, availableHeight - 40))
    popover.contentSize = NSSize(width: UsageMenuView.width, height: height)
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
      if self?.popover.isShown == true {
        self?.resizePopoverToFitContent()
      }
    }
    .store(in: &cancellables)

    Publishers.CombineLatest(viewModel.$resetRadar, viewModel.$resetRadarError)
      .receive(on: RunLoop.main)
      .sink { [weak self] _, _ in
        if self?.popover.isShown == true {
          self?.resizePopoverToFitContent()
        }
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
      badgeIntegrationModel.refresh()
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
