/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// DisplayViewModel.swift
//
// Manages the display session lifecycle: attaching to a display-capable device,
// sending views, and detaching. Uses DSPN's pending action pattern so that
// tapping "play" auto-attaches and sends the view once the display is ready.
//

import MWDATCore
import MWDATDisplay
import Observation
import SwiftUI

@Observable
@MainActor
class DisplayViewModel {
  var isConnected: Bool = false
  var isSending: Bool = false
  var errorMessage: String?
  var requiresDATAppUpdate: Bool = false
  var didFailToStartSession: Bool = false

  @ObservationIgnored private let wearables: WearablesInterface
  @ObservationIgnored private var deviceSelector: AutoDeviceSelector
  @ObservationIgnored private var deviceSession: DeviceSession?
  @ObservationIgnored private var display: Display?
  @ObservationIgnored private var stateListenerToken: AnyListenerToken?
  @ObservationIgnored private var coreStateTask: Task<Void, Never>?
  @ObservationIgnored private var sessionErrorTask: Task<Void, Never>?
  @ObservationIgnored private var registrationTask: Task<Void, Never>?
  @ObservationIgnored private var displayStateTask: Task<Void, Never>?
  @ObservationIgnored private var displayStateContinuation: AsyncStream<DisplayState>.Continuation?
  @ObservationIgnored private var pendingAction: (() async -> Void)?

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.deviceSelector = AutoDeviceSelector(wearables: wearables, filter: { $0.supportsDisplay() })
    observeRegistration()
  }

  isolated deinit {
    stateListenerToken = nil
    coreStateTask?.cancel()
    sessionErrorTask?.cancel()
    registrationTask?.cancel()
    displayStateTask?.cancel()
  }

  // MARK: - Registration Observation

  private func observeRegistration() {
    registrationTask = Task { [weak self] in
      guard let wearables = self?.wearables else { return }
      for await state in wearables.registrationStateStream() {
        guard let self, !Task.isCancelled else { return }
        if state == .available || state == .unavailable {
          self.resetDisplaySession()
        }
      }
    }
  }

  private func resetDisplaySession() {
    detachFromDisplay()
    deviceSelector = AutoDeviceSelector(wearables: wearables, filter: { $0.supportsDisplay() })
  }

  // MARK: - Public API

  /// Sends a display view to the glasses. Auto-attaches if not connected;
  /// the view is queued and sent once the display session is ready.
  func send(_ view: some DisplayableView) async {
    if let display, isConnected {
      await doSend(view, on: display)
      return
    }

    // Store as pending action — will fire once display is ready
    let sendableView = view
    pendingAction = { [weak self] in
      guard let self, let cap = self.display else { return }
      await self.doSend(sendableView, on: cap)
    }

    if display == nil {
      await attachToDisplay()
    }
  }

  private func doSend(_ view: some DisplayableView, on capability: Display) async {
    isSending = true
    defer { isSending = false }

    do {
      try await capability.send(view)
    } catch {
      let message = (error as? DisplayError)?.description ?? error.localizedDescription
      errorMessage = message
    }
  }

  // MARK: - Session Management

  func attachToDisplay() async {
    guard display == nil else { return }

    didFailToStartSession = false

    do {
      let devSession = try wearables.createSession(deviceSelector: deviceSelector)
      deviceSession = devSession

      let stateStream = devSession.stateStream()
      let errorStream = devSession.errorStream()
      coreStateTask = Task { [weak self] in
        for await sessionState in stateStream {
          guard let self, !Task.isCancelled else { return }
          switch sessionState {
          case .started:
            self.requiresDATAppUpdate = false
            self.didFailToStartSession = false
            await self.setupDisplay(on: devSession)
          case .stopping, .stopped:
            self.isConnected = false
            self.display = nil
          case .starting, .idle, .paused:
            break
          @unknown default:
            break
          }
        }
      }
      sessionErrorTask = Task { [weak self] in
        for await error in errorStream {
          guard let self, !Task.isCancelled else { return }
          self.handleSessionError(error)
        }
      }

      try devSession.start()
    } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
      requiresDATAppUpdate = true
      didFailToStartSession = true
      errorMessage = DeviceSessionError.datAppOnTheGlassesUpdateRequired.localizedDescription
    } catch {
      requiresDATAppUpdate = false
      didFailToStartSession = true
      errorMessage = "Failed to create session: \(error.localizedDescription)"
    }
  }

  func clearSessionStartFailure() {
    didFailToStartSession = false
  }

  private func setupDisplay(on devSession: DeviceSession) async {
    guard display == nil else { return }

    do {
      let capability = try devSession.addDisplay()

      let (stateStream, continuation) = AsyncStream.makeStream(of: DisplayState.self)
      displayStateContinuation = continuation
      stateListenerToken = capability.statePublisher.listen { state in
        continuation.yield(state)
      }

      displayStateTask = Task { [weak self] in
        for await state in stateStream {
          guard let self, !Task.isCancelled else { return }
          switch state {
          case .starting:
            break
          case .started:
            self.isConnected = true
            // Execute pending action now that display is ready
            if let action = self.pendingAction {
              self.pendingAction = nil
              await action()
            }
          case .stopping:
            self.isConnected = false
          case .stopped:
            self.isConnected = false
            self.stateListenerToken = nil
            self.displayStateContinuation?.finish()
            self.displayStateContinuation = nil
            self.display = nil
            self.coreStateTask?.cancel()
            self.coreStateTask = nil
            self.sessionErrorTask?.cancel()
            self.sessionErrorTask = nil
            self.deviceSession?.stop()
            self.deviceSession = nil
          }
        }
      }

      capability.start()
      display = capability
    } catch {
      errorMessage = "Failed to start display: \(error.localizedDescription)"
    }
  }

  // MARK: - Car Maintenance

  func sendCarMaintenanceTutorialList() async {
    await send(
      CarMaintenanceDisplay.tutorialList { [weak self] index in
        Task { @MainActor in
          await self?.sendCarMaintenanceTutorialDetail(tutorialIndex: index)
        }
      }
    )
  }

  func sendCarMaintenanceTutorialDetail(tutorialIndex: Int) async {
    await send(
      CarMaintenanceDisplay.tutorialDetail(
        tutorialIndex: tutorialIndex,
        onBack: { [weak self] in
          Task { @MainActor in
            await self?.sendCarMaintenanceTutorialList()
          }
        },
        onStart: { [weak self] in
          Task { @MainActor in
            await self?.sendCarMaintenanceTutorialStep(tutorialIndex: tutorialIndex, stepIndex: 0)
          }
        }
      )
    )
  }

  func sendTutorialVideo(tutorialIndex: Int, stepIndex: Int) async {
    await send(CarMaintenanceDisplay.tutorialVideo())
    display?.onPlaybackEvent = { [weak self] event in
      if event.type == .ended {
        Task { @MainActor [weak self] in
          self?.display?.onPlaybackEvent = nil
          await self?.sendCarMaintenanceTutorialStep(
            tutorialIndex: tutorialIndex,
            stepIndex: stepIndex
          )
        }
      }
    }
  }

  func sendCarMaintenanceTutorialStep(tutorialIndex: Int, stepIndex: Int) async {
    let isLastStep = stepIndex == CarMaintenanceDisplay.tutorials[tutorialIndex].steps.count - 1
    await send(
      CarMaintenanceDisplay.tutorialStep(
        tutorialIndex: tutorialIndex,
        stepIndex: stepIndex,
        onPrevious: { [weak self] in
          Task { @MainActor in
            if stepIndex == 0 {
              await self?.sendCarMaintenanceTutorialDetail(tutorialIndex: tutorialIndex)
            } else {
              await self?.sendCarMaintenanceTutorialStep(
                tutorialIndex: tutorialIndex,
                stepIndex: stepIndex - 1
              )
            }
          }
        },
        onNext: { [weak self] in
          Task { @MainActor in
            if isLastStep {
              await self?.sendCarMaintenanceTutorialList()
            } else {
              await self?.sendCarMaintenanceTutorialStep(
                tutorialIndex: tutorialIndex,
                stepIndex: stepIndex + 1
              )
            }
          }
        },
        onWatchVideo: { [weak self] in
          Task { @MainActor in
            await self?.sendTutorialVideo(tutorialIndex: tutorialIndex, stepIndex: stepIndex)
          }
        }
      )
    )
  }

  func detachFromDisplay() {
    if let display {
      display.stop()
    } else {
      coreStateTask?.cancel()
      coreStateTask = nil
      sessionErrorTask?.cancel()
      sessionErrorTask = nil
      deviceSession?.stop()
      deviceSession = nil
    }
  }

  private func handleSessionError(_ error: DeviceSessionError) {
    requiresDATAppUpdate = error == .datAppOnTheGlassesUpdateRequired
    didFailToStartSession = true
    errorMessage = error.localizedDescription
  }
}
