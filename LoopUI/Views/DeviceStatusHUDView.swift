//
//  DeviceStatusHUDView.swift
//  LoopUI
//
//  Created by Nathaniel Hamming on 2020-06-05.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import UIKit
import HealthKit
import LoopKit
import LoopKitUI

@objc open class DeviceStatusHUDView: BaseHUDView {
    
    var statusHighlightView: StatusHighlightHUDView! {
        didSet {
            statusHighlightView.isHidden = true
        }
    }
    
    @IBOutlet private var statusBadgeView: StatusBadgeHUDView! {
        didSet {
            statusBadgeView.isHidden = true
        }
    }
    
    @IBOutlet private weak var progressView: UIProgressView! {
        didSet {
            progressView.isHidden = true
            progressView.tintColor = .systemGray
            // round the edges of the progress view
            progressView.layer.cornerRadius = 2
            progressView.clipsToBounds = true
            progressView.layer.sublayers!.last!.cornerRadius = 2
            progressView.subviews.last!.clipsToBounds = true
        }
    }
    
    @IBOutlet private weak var backgroundView: UIView! {
        didSet {
            backgroundView.backgroundColor = .systemBackground
            backgroundView.layer.cornerRadius = 23
        }
    }
    
    @IBOutlet weak var statusStackView: UIStackView!
    
    public var lifecycleProgress: DeviceLifecycleProgress? {
        didSet {
            guard let lifecycleProgress = lifecycleProgress else {
                resetProgress()
                return
            }
             
            progressView.isHidden = false
            progressView.progress = Float(lifecycleProgress.percentComplete.clamped(to: 0...1))
            progressView.tintColor = lifecycleProgress.progressState.color
            positionFootnote()
        }
    }

    // MARK: - Footnote (PowerPack)

    /// Small grey line shown just under the pill (DirectConnect uses it for the last sensor
    /// contact). Placed below the lifecycle progress bar when that bar is showing. nil hides it.
    public var footnote: NSAttributedString? {
        didSet {
            guard footnote != oldValue else { return }
            if footnote != nil, footnoteLabel.superview == nil {
                installFootnoteLabel()
            }
            footnoteLabel.attributedText = footnote
            footnoteLabel.isHidden = footnote == nil
            positionFootnote()
        }
    }

    private lazy var footnoteLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        label.isAccessibilityElement = false
        return label
    }()

    /// The strip between the pill (or the progress bar, when shown) and the bottom of this view,
    /// which is where the next block on the screen starts. The footnote is centered in it.
    private let footnoteGap = UILayoutGuide()
    private var footnoteUnderPill: NSLayoutConstraint?
    private var footnoteUnderProgress: NSLayoutConstraint?

    private func installFootnoteLabel() {
        guard let backgroundView = backgroundView else { return }
        addSubview(footnoteLabel)
        addLayoutGuide(footnoteGap)
        footnoteUnderPill = footnoteGap.topAnchor.constraint(equalTo: backgroundView.bottomAnchor)
        footnoteUnderProgress = footnoteGap.topAnchor.constraint(equalTo: progressView.bottomAnchor)
        NSLayoutConstraint.activate([
            footnoteGap.bottomAnchor.constraint(equalTo: bottomAnchor),
            footnoteLabel.centerYAnchor.constraint(equalTo: footnoteGap.centerYAnchor),
            footnoteLabel.centerXAnchor.constraint(equalTo: backgroundView.centerXAnchor),
            footnoteLabel.widthAnchor.constraint(lessThanOrEqualTo: backgroundView.widthAnchor),
        ])
        positionFootnote()
    }

    private func positionFootnote() {
        guard footnoteLabel.superview != nil else { return }
        let underProgress = !progressView.isHidden
        footnoteUnderPill?.isActive = !underProgress
        footnoteUnderProgress?.isActive = underProgress
    }
    
    public var adjustViewsForNarrowDisplay: Bool = false {
        didSet {
            if adjustViewsForNarrowDisplay != oldValue {
                NSLayoutConstraint.activate([
                    statusHighlightView.icon.widthAnchor.constraint(equalToConstant: 26),
                    statusHighlightView.icon.heightAnchor.constraint(equalToConstant: 26),
                ])
            } else {
                NSLayoutConstraint.activate([
                    statusHighlightView.icon.widthAnchor.constraint(equalToConstant: 34),
                    statusHighlightView.icon.heightAnchor.constraint(equalToConstant: 34),
                ])
            }
        }
    }
    
    private func resetProgress() {
        progressView.isHidden = true
        progressView.progress = 0
        positionFootnote()
    }
    
    func setup() {
        if statusHighlightView == nil {
            statusHighlightView = StatusHighlightHUDView(frame: self.frame)
        }
    }
    
    public func presentStatusHighlight(_ statusHighlight: DeviceStatusHighlight?) {
        guard let statusHighlight = statusHighlight else {
            dismissStatusHighlight()
            return
        }
        
        presentStatusHighlight(withMessage: statusHighlight.localizedMessage,
                               image: statusHighlight.image,
                               color: statusHighlight.state.color)
    }
    
    private func presentStatusHighlight(withMessage message: String,
                                       image: UIImage?,
                                       color: UIColor)
    {
        statusHighlightView.messageLabel.text = message
        statusHighlightView.messageLabel.tintColor = .label
        statusHighlightView.icon.image = image
        statusHighlightView.icon.tintColor = color
        presentStatusHighlight()
    }
    
    func presentStatusHighlight() {
        statusStackView?.addArrangedSubview(statusHighlightView)
        statusHighlightView.isHidden = false
    }
    
    func dismissStatusHighlight() {
        // need to also hide this view, since it will be added back to the stack at some point
        statusHighlightView.isHidden = true
        statusStackView?.removeArrangedSubview(statusHighlightView)
    }
    
    public func presentStatusBadge(_ statusBadge: DeviceStatusBadge?) {
        guard let statusBadge = statusBadge else {
            dismissStatusBadge()
            return
        }
        
        presentStatusBadge(withIcon: statusBadge.image,
                           color: statusBadge.state.color)
    }
    
    private func presentStatusBadge(withIcon badgeIcon: UIImage?,
                                    color: UIColor) {
        statusBadgeView.setBadgeIcon(badgeIcon)
        statusBadgeView.tintColor = color
        presentStatusBadge()
    }
    
    private func presentStatusBadge() {
        statusBadgeView.isHidden = false
    }
    
    private func dismissStatusBadge() {
        statusBadgeView.isHidden = true
    }
}
