import Foundation
import UIKit

private func PBSwizzleMethod(clazz: AnyClass?, original: Selector, alternate: Selector) {
    guard let origMethod = class_getInstanceMethod(clazz, original),
          let newMethod = class_getInstanceMethod(clazz, alternate) else {
        return
    }
    
    if class_addMethod(clazz, original, method_getImplementation(newMethod), method_getTypeEncoding(newMethod)) {
        class_replaceMethod(clazz, alternate, method_getImplementation(origMethod), method_getTypeEncoding(origMethod))
    } else {
        method_exchangeImplementations(origMethod, newMethod)
    }
}

/**
 *  A helper function to force table view to update its content size
 *
 *  See https://github.com/pronebird/UIScrollView-InfiniteScroll/issues/31
 *
 *  @param tableView table view
 */
private func PBForceUpdateTableViewContentSize(tableView: UITableView) {
    tableView.contentSize = tableView.sizeThatFits(.init(width: tableView.frame.width,
                                                         height: CGFloat.greatestFiniteMagnitude))
}

// Animation duration used for setContentOffset:
private let kPBInfiniteScrollAnimationDuration: TimeInterval = 0.35

/**
 Enum that describes the infinite scroll direction.
 */
public enum InfiniteScrollDirection {
    /**
     *  Trigger infinite scroll when the scroll view reaches the bottom.
     *  This is the default. It is also the only supported direction for
     *  table views.
     */
    case vertical
    
    /**
     *  Trigger infinite scroll when the scroll view reaches the right edge.
     *  This should be used for horizontally scrolling collection views.
     */
    case horizontal
}

public protocol InfiniteActivityIndicator: UIView {
    func startAnimating()
    func stopAnimating()
}

extension UIActivityIndicatorView: InfiniteActivityIndicator {}

// MARK: - Infinite scroll state
/**
 *  Infinite scroll state class.
 *  @private
 */
private class _PBInfiniteScrollState: NSObject {
    
    /**
     *  A flag that indicates whether scroll is initialized
     */
    var initialized: Bool = false
    
    /**
     *  A flag that indicates whether loading is in progress.
     */
    var loading: Bool = false
    
    /**
     * The direction that the infinite scroll is working in.
     */
    var direction: InfiniteScrollDirection = .vertical
    
    /**
     *  Indicator view.
     */
    var indicatorView: InfiniteActivityIndicator?
    
    /**
     *  Indicator style when UIActivityIndicatorView used.
     */
    var indicatorStyle: UIActivityIndicatorView.Style
    
    /**
     *  Flag used to return user back to start of scroll view
     *  when loading initial content.
     */
    var scrollToStartWhenFinished: Bool = false
    
    /**
     *  Extra padding to push indicator view outside view bounds.
     *  Used in case when content size is smaller than view bounds
     */
    var extraEndInset: CGFloat = 0
    
    /**
     *  Indicator view inset.
     *  Essentially is equal to indicator view height.
     */
    var indicatorInset: CGFloat = 0
    
    /**
     *  Indicator view margin (top and bottom for vertical direction
     *  or left and right for horizontal direction)
     */
    var indicatorMargin: CGFloat = 0
    
    /**
     *  Trigger offset.
     */
    var triggerOffset: CGFloat = 0
    
    /**
     *  Infinite scroll handler block
     */
    var infiniteScrollHandler: ((UIScrollView) -> Void)?
    
    /**
     *  Infinite scroll allowed block
     *  Return NO to block the infinite scroll. Useful to stop requests when you have shown all results, etc.
     */
    var shouldShowInfiniteScrollHandler: ((UIScrollView) -> Bool)?
    
    override init() {
        
        #if os(tvOS)
        if #available(tvOS 13.0, *) {
            indicatorStyle = .large
        } else {
            indicatorStyle = .white
        }
        #else
        if #available(iOS 13.0, *) {
            indicatorStyle = .medium
        } else {
            indicatorStyle = .gray
        }
        #endif
        
        super.init()
        
        // Default row height (44) minus activity indicator height (22) / 2
        indicatorMargin = 11.0
        
        direction = .vertical
    }
}

private extension UIScrollView {
    static var swizzled: Bool = false
}

public extension UIScrollView {
    
    /// Method swizzling, must be called once
    static func swizzleInfiniteScrolls() {
        if swizzled {
            return
        }

        swizzled = true
        
        PBSwizzleMethod(clazz: self,
                        original: #selector(setter: contentOffset),
                        alternate: #selector(pb_setContentOffset(_:)))
        PBSwizzleMethod(clazz: self,
                        original: #selector(setter: contentSize),
                        alternate: #selector(pb_setContentSize(_:)))
    }
}

public extension UIScrollView {
    
    // MARK: - Public
    
    /**
     *  Setup infinite scroll handler
     *
     *  @param handler a handler block
     */
    func addInfiniteScroll(handler: ((UIScrollView) -> Void)?) {
        let state = self.pb_infiniteScrollState
        
        // Save handler block
        state.infiniteScrollHandler = handler
        
        // Double initialization only replaces handler block
        // Do not continue if already initialized
        if state.initialized {
            return
        }
        
        // Add pan guesture handler
        self.panGestureRecognizer.addTarget(self, action: #selector(pb_handlePanGesture(_:)))
        
        // Mark infiniteScroll initialized
        state.initialized = true
    }
    
    /**
     *  Unregister infinite scroll
     */
    func removeInfiniteScroll() {
        let state = self.pb_infiniteScrollState
        
        // Ignore multiple calls to remove infinite scroll
        if !state.initialized {
            return
        }
        
        // Remove pan gesture handler
        self.panGestureRecognizer.removeTarget(self, action: #selector(pb_handlePanGesture(_:)))
        
        // Destroy infinite scroll indicator
        state.indicatorView?.removeFromSuperview()
        state.indicatorView = nil
        
        // Release handler block
        state.infiniteScrollHandler = nil
        
        // Mark infinite scroll as uninitialized
        state.initialized = false
    }
    
    /**
     *  Manually begin infinite scroll animations
     *
     *  This method provides identical behavior to user initiated scrolling.
     *
     *  @param forceScroll pass YES to scroll to indicator view
     */
    func beginInfiniteScroll(forceScroll: Bool) {
        pb_beginInfinitScrollIfNeeded(forceScroll: forceScroll)
    }
    
    /**
     *  Finish infinite scroll animations
     *
     *  You must call this method from your infinite scroll handler to finish all
     *  animations properly and reset infinite scroll state
     *
     *  @param handler a completion block handler called when animation finished
     */
    func finishInfiniteScroll(completion: ((UIScrollView) -> Void)? = nil) {
        if self.pb_infiniteScrollState.loading {
            pb_stopAnimatingInfiniteScroll(completion: completion)
        }
    }
    
    // MARK: - Accessors
    
    /**
     * The direction that the infinite scroll should work in (default: InfiniteScrollDirectionVertical).
     */
    var infiniteScrollDirection: InfiniteScrollDirection {
        get { pb_infiniteScrollState.direction }
        set { pb_infiniteScrollState.direction = newValue }
    }
    
    /**
     *  Flag that indicates whether infinite scroll is animating
     */
    var isAnimatingInfiniteScroll: Bool {
        pb_infiniteScrollState.loading
    }
    
    /**
     *  Infinite scroll activity indicator style (default: UIActivityIndicatorViewStyleGray on iOS, UIActivityIndicatorViewStyleWhite on tvOS)
     */
    var infiniteScrollIndicatorStyle: UIActivityIndicatorView.Style {
        get { pb_infiniteScrollState.indicatorStyle }
        set {
            let state = self.pb_infiniteScrollState
            state.indicatorStyle = newValue
            
            if let activityIndicatorView = state.indicatorView as? UIActivityIndicatorView {
                activityIndicatorView.style = newValue
            }
        }
    }
    
    /**
     *  Infinite indicator view
     *
     *  You can set your own custom view instead of default activity indicator,
     *  make sure it implements methods below:
     *
     *  * `- (void)startAnimating`
     *  * `- (void)stopAnimating`
     *
     *  Infinite scroll will call implemented methods during user interaction.
     */
    var infiniteScrollIndicatorView: InfiniteActivityIndicator? {
        get { pb_infiniteScrollState.indicatorView }
        set {
            // make sure indicator is initially hidden
            newValue?.isHidden = true
            pb_infiniteScrollState.indicatorView = newValue
        }
    }
    
    /**
     *  The margin from the scroll view content to the indicator view (Default: 11)
     */
    var infiniteScrollIndicatorMargin: CGFloat {
        get { pb_infiniteScrollState.indicatorMargin }
        set { pb_infiniteScrollState.indicatorMargin = newValue }
    }
    
    /**
     *  Set a handler to be called to check if the infinite scroll should be shown
     *
     *  @param handler a handler block
     */
    func setShouldShowInfiniteScrollHandler(_ handler: ((UIScrollView) -> Bool)?) {
        let state = self.pb_infiniteScrollState
        
        // Save handler block
        state.shouldShowInfiniteScrollHandler = handler
    }
    
    /**
     *  Set adjustment for scroll coordinate used to determine when to call handler block.
     *  Non-zero value advances the point when handler block is being called
     *  making it fire by N points earlier before scroll view reaches the bottom or right edge.
     *  This value is measured in points and must be positive number.
     *  Default: 0.0
     */
    var infiniteScrollTriggerOffset: CGFloat {
        get { pb_infiniteScrollState.triggerOffset }
        set {
            pb_infiniteScrollState.triggerOffset = abs(newValue)
        }
    }
}

/**
 *  Private category on UIScrollView to define dynamic properties.
 */
extension UIScrollView {
    
    /// Keys for values in associated dictionary
    private struct AssociatedKeys {
        static var kPBInfiniteScrollStateKey = "kPBInfiniteScrollStateKey"
    }
    
    private func associatedObject<ValueType>(
        base: AnyObject,
        key: UnsafePointer<String>,
        defaultValue: ValueType)
        -> ValueType {
            if let associated = objc_getAssociatedObject(base, key)
                as? ValueType { return associated }
            let associated = defaultValue
            objc_setAssociatedObject(base, key, associated, .OBJC_ASSOCIATION_RETAIN)
            return associated
    }

    private func associateObject<ValueType>(
        base: AnyObject,
        key: UnsafePointer<String>,
        value: ValueType) {
        objc_setAssociatedObject(base, key, value, .OBJC_ASSOCIATION_RETAIN)
    }
    
    /**
     *  Infinite scroll state.
     */
    private var pb_infiniteScrollState: _PBInfiniteScrollState {
        if let state: _PBInfiniteScrollState = associatedObject(
            base: self,
            key: &AssociatedKeys.kPBInfiniteScrollStateKey,
            defaultValue: nil) {
            return state
        }
        
        let newState = _PBInfiniteScrollState()
        associateObject(base: self,
                        key: &AssociatedKeys.kPBInfiniteScrollStateKey,
                        value: newState)
        return newState
    }
}

extension UIScrollView {
    
    // MARK: - Private methods
    
    /**
     *  Additional pan gesture handler used to adjust content offset to reveal or hide indicator view.
     *
     *  @param gestureRecognizer gesture recognizer
     */
    @objc private func pb_handlePanGesture(_ gestureRecognizer: UITapGestureRecognizer) {
        if gestureRecognizer.state == .ended {
            pb_scrollToInfiniteIndicatorIfNeeded(reveal: true, force: false)
        }
    }
    
    /**
     *  This is a swizzled proxy method for setContentOffset of UIScrollView.
     *
     *  @param contentOffset content offset
     */
    @objc private func pb_setContentOffset(_ contentOffset: CGPoint) {
        pb_setContentOffset(contentOffset)
        
        if pb_infiniteScrollState.initialized {
            pb_scrollViewDidScroll(contentOffset: contentOffset)
        }
    }
    
    /**
     *  This is a swizzled proxy method for setContentSize of UIScrollView
     *
     *  @param contentSize content size
     */
    @objc private func pb_setContentSize(_ contentSize: CGSize) {
        pb_setContentSize(contentSize)
        
        if pb_infiniteScrollState.initialized {
            pb_positionInfiniteScrollIndicator(contentSize: contentSize)
        }
    }
    
    /**
     *  Clamp content size to fit visible bounds of scroll view.
     *  Visible area is a scroll view size minus original top and bottom insets for vertical direction,
     *  or minus original left and right insets for horizontal direction.
     *
     *  @param contentSize content size
     *
     *  @return CGFloat
     */
    private func pb_clampContentSizeToFitVisibleBounds(contentSize: CGSize) -> CGFloat {
        let adjustedContentInset = pb_adjustedContentInset()
        
        // Find minimum content height. Only original insets are used in calculation.
        if pb_infiniteScrollState.direction == .vertical {
            let minHeight = self.bounds.size.height - adjustedContentInset.top - pb_originalEndInset()
            return max(contentSize.height, minHeight)
        } else {
            let minWidth = self.bounds.size.width - adjustedContentInset.left - pb_originalEndInset()
            return max(contentSize.width, minWidth)
        }
    }
    
    /**
     *  Checks if UIScrollView is empty.
     *
     *  @return BOOL
     */
    private func pb_hasContent() -> Bool {
        var constant: CGFloat = 0
        
        // Default UITableView reports height = 1 on empty tables
        if self is UITableView {
            constant = 1
        }
        
        if pb_infiniteScrollState.direction == .vertical {
            return self.contentSize.height > constant
        } else {
            return self.contentSize.width > constant
        }
    }
    
    /**
     *  Returns end (bottom or right) inset without extra padding and indicator padding.
     *
     *  @return CGFloat
     */
    private func pb_originalEndInset() -> CGFloat {
        let adjustedContentInset = pb_adjustedContentInset()
        let state = self.pb_infiniteScrollState
        
        if state.direction == .vertical {
            return adjustedContentInset.bottom - state.extraEndInset - state.indicatorInset
        } else {
            return adjustedContentInset.right - state.extraEndInset - state.indicatorInset
        }
    }
    
    /**
     *  Returns `adjustedContentInset` on iOS 11+, or `contentInset` on earlier iOS
     */
    private func pb_adjustedContentInset() -> UIEdgeInsets {
        if #available(iOS 11, tvOS 11, *) {
            return self.adjustedContentInset
        } else {
            return self.contentInset
        }
    }
    
    /**
     *  Call infinite scroll handler block, primarily here because we use performSelector to call this method.
     */
    private func pb_callInfiniteScrollHandler() {
        let state = self.pb_infiniteScrollState
        state.infiniteScrollHandler?(self);
    }
    
    /**
     *  Guaranteed to return an indicator view.
     *
     *  @return indicator view.
     */
    private func pb_getOrCreateActivityIndicatorView() -> InfiniteActivityIndicator {
        var activityIndicator = self.infiniteScrollIndicatorView
        
        if activityIndicator == nil {
            activityIndicator = UIActivityIndicatorView(style: self.infiniteScrollIndicatorStyle)
            self.infiniteScrollIndicatorView = activityIndicator
        }
        
        // Add activity indicator into scroll view if needed
        if activityIndicator?.superview != self {
            addSubview(activityIndicator!)
        }
        
        return activityIndicator!
    }
    
    /**
     *  A row height for indicator view, in other words: indicator margin + indicator height.
     *
     *  @return CGFloat
     */
    private func pb_infiniteIndicatorRowSize() -> CGFloat {
        let activityIndicator = pb_getOrCreateActivityIndicatorView()
        
        if pb_infiniteScrollState.direction == .vertical {
            let indicatorHeight = activityIndicator.bounds.height
            return indicatorHeight + self.infiniteScrollIndicatorMargin * 2
        } else {
            let indicatorWidth = activityIndicator.bounds.width
            return indicatorWidth + self.infiniteScrollIndicatorMargin * 2
        }
    }
    
    /**
     *  Update infinite scroll indicator's position in view.
     *
     *  @param contentSize content size.
     */
    private func pb_positionInfiniteScrollIndicator(contentSize: CGSize) {
        let activityIndicator = pb_getOrCreateActivityIndicatorView()
        let contentLength = pb_clampContentSizeToFitVisibleBounds(contentSize: contentSize)
        let indicatorRowSize = pb_infiniteIndicatorRowSize()
        
        var center: CGPoint
        
        if pb_infiniteScrollState.direction == .vertical {
            center = CGPoint(x: contentSize.width * 0.5, y: contentLength + indicatorRowSize * 0.5)
        } else {
            center = CGPoint(x: contentLength + indicatorRowSize * 0.5, y: contentSize.height * 0.5)
        }
        
        if activityIndicator.center != center {
            activityIndicator.center = center
        }
    }
    
    /**
     *  Update infinite scroll indicator's position in view.
     *
     *  @param forceScroll force scroll to indicator view
     */
    private func pb_beginInfinitScrollIfNeeded(forceScroll: Bool) {
        let state = self.pb_infiniteScrollState
        
        // already loading?
        if state.loading {
            return
        }
        
        // Only show the infinite scroll if it is allowed
        if pb_shouldShowInfiniteScroll() {
            pb_startAnimatingInfiniteScroll(forceScroll: forceScroll)
            
            // This will delay handler execution until scroll deceleration
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
                self.pb_callInfiniteScrollHandler()
            }
        }
    }
    
    /**
     *  Start animating infinite indicator
     */
    private func pb_startAnimatingInfiniteScroll(forceScroll: Bool) {
        let state = self.pb_infiniteScrollState
        let activityIndicator = pb_getOrCreateActivityIndicatorView()
        
        // Layout indicator view
        pb_positionInfiniteScrollIndicator(contentSize: self.contentSize)
        
        // It's show time!
        activityIndicator.isHidden = true
        activityIndicator.startAnimating()
        
        // Calculate indicator view inset
        let indicatorInset = pb_infiniteIndicatorRowSize()
        
        var contentInset = self.contentInset
        
        // Make a room to accommodate indicator view
        if state.direction == .vertical {
            contentInset.bottom += indicatorInset
        } else {
            contentInset.right += indicatorInset
        }
        
        // We have to pad scroll view when content size is smaller than view bounds.
        // This will guarantee that indicator view appears at the very end of scroll view.
        let adjustedContentSize = pb_clampContentSizeToFitVisibleBounds(contentSize: self.contentSize)
        // Add empty space padding
        if state.direction == .vertical {
            let extraBottomInset = adjustedContentSize - self.contentSize.height
            contentInset.bottom += extraBottomInset
            
            // Save extra inset
            state.extraEndInset = extraBottomInset
        } else {
            let extraRightInset = adjustedContentSize - self.contentSize.width
            contentInset.right += extraRightInset
            
            // Save extra inset
            state.extraEndInset = extraRightInset
        }
        
        // Save indicator view inset
        state.indicatorInset = indicatorInset
        
        // Update infinite scroll state
        state.loading = true
        
        // Scroll to start if scroll view had no content before update
        state.scrollToStartWhenFinished = !pb_hasContent()
        
        // Animate content insets
        pb_setScrollViewContentInset(contentInset, animated: true) { finished in
            if finished {
                self.pb_scrollToInfiniteIndicatorIfNeeded(reveal: true, force: forceScroll)
            }
        }
    }
    
    /**
     *  Stop animating infinite scroll indicator
     *
     *  @param handler a completion handler
     */
    private func pb_stopAnimatingInfiniteScroll(completion: ((UIScrollView) -> Void)? = nil) {
        let state = self.pb_infiniteScrollState
        let activityIndicator = self.infiniteScrollIndicatorView
        var contentInset = self.contentInset
        
        // Force the table view to update its contentSize; if we don't do this,
        // finishInfiniteScroll() will adjust contentInsets and cause contentOffset
        // to be off by an amount equal to the height of the activity indicator.
        // See https://github.com/pronebird/UIScrollView-InfiniteScroll/issues/31
        // Note: this call has to happen before we reset extraBottomInset or indicatorInset
        //       otherwise indicator may re-layout at the wrong position but we haven't set
        //       contentInset yet!
        if let tableView = self as? UITableView {
            PBForceUpdateTableViewContentSize(tableView: tableView)
        }
        
        if state.direction == .vertical {
            // Remove row height inset
            contentInset.bottom -= state.indicatorInset
            // Remove extra inset added to pad infinite scroll
            contentInset.bottom -= state.extraEndInset
        } else {
            // Remove row height inset
            contentInset.right -= state.indicatorInset
            // Remove extra inset added to pad infinite scroll
            contentInset.right -= state.extraEndInset
        }
        
        // Reset indicator view inset
        state.indicatorInset = 0
        
        // Reset extra end inset
        state.extraEndInset = 0
        
        // Animate content insets
        pb_setScrollViewContentInset(contentInset, animated: true) { finished in
            // Initiate scroll to the end if due to user interaction contentOffset
            // stuck somewhere between last cell and activity indicator
            if finished {
                if state.scrollToStartWhenFinished {
                    self.pb_scrollToStart()
                } else {
                    self.pb_scrollToInfiniteIndicatorIfNeeded(reveal: false, force: false)
                }
            }
            
            // Curtain is closing they're throwing roses at my feet
            activityIndicator?.stopAnimating()
            activityIndicator?.isHidden = true
            
            // Reset scroll state
            state.loading = false
            
            // Call completion handler
            completion?(self)
        }
    }
    
    private func pb_shouldShowInfiniteScroll() -> Bool {
        let state = self.pb_infiniteScrollState
        
        // Ensure we should show the inifinite scroll
        return state.shouldShowInfiniteScrollHandler?(self) ?? true
    }
    
    /**
     *  Called whenever content offset changes.
     *
     *  @param contentOffset content offset
     */
    private func pb_scrollViewDidScroll(contentOffset: CGPoint) {
        // is user initiated?
        if !isDragging && !UIAccessibility.isVoiceOverRunning {
            return
        }
        
        let state = self.pb_infiniteScrollState
        
        let contentSize = pb_clampContentSizeToFitVisibleBounds(contentSize: self.contentSize)
        
        if state.direction == .vertical {
            // The lower bound when infinite scroll should kick in
            var actionOffset = CGPoint.zero
            actionOffset.x = 0;
            actionOffset.y = contentSize - self.bounds.size.height + pb_originalEndInset()
            
            // apply trigger offset adjustment
            actionOffset.y -= state.triggerOffset
            
            if contentOffset.y > actionOffset.y && panGestureRecognizer.velocity(in: self).y <= 0 {
                pb_beginInfinitScrollIfNeeded(forceScroll: false)
            }
        } else {
            // The lower bound when infinite scroll should kick in
            var actionOffset = CGPoint.zero
            actionOffset.x = contentSize - self.bounds.size.width + pb_originalEndInset()
            actionOffset.y = 0
            
            // apply trigger offset adjustment
            actionOffset.x -= state.triggerOffset
            
            if contentOffset.x > actionOffset.x && panGestureRecognizer.velocity(in: self).x <= 0 {
                pb_beginInfinitScrollIfNeeded(forceScroll: false)
            }
        }
    }
    
    /**
     *  Scrolls view to start
     */
    private func pb_scrollToStart() {
        let adjustedContentInset = pb_adjustedContentInset()
        var pt = CGPoint.zero
        
        if pb_infiniteScrollState.direction == .vertical {
            pt.x = self.contentOffset.x
            pt.y = adjustedContentInset.top * -1
        } else {
            pt.x = adjustedContentInset.left * -1
            pt.y = self.contentOffset.y
        }
        
        setContentOffset(pt, animated: true)
    }
    
    /**
     *  Scrolls to activity indicator if it is partially visible
     *
     *  @param reveal scroll to reveal or hide activity indicator
     *  @param force forces scroll to bottom
     */
    private func pb_scrollToInfiniteIndicatorIfNeeded(reveal: Bool, force: Bool) {
        // do not interfere with user
        if isDragging {
            return
        }
        
        let state = self.pb_infiniteScrollState
        
        // filter out calls from pan gesture
        if !state.loading {
            return
        }
        
        // Force table view to update content size
        if let tableView = self as? UITableView {
            PBForceUpdateTableViewContentSize(tableView: tableView)
        }
        
        let contentSize = pb_clampContentSizeToFitVisibleBounds(contentSize: self.contentSize)
        let indicatorRowSize = pb_infiniteIndicatorRowSize()
        
        if state.direction == .vertical {
            let minY = contentSize - self.bounds.size.height + pb_originalEndInset()
            let maxY = minY + indicatorRowSize
            
            if (self.contentOffset.y > minY && self.contentOffset.y < maxY) || force {
                
                // Use -scrollToRowAtIndexPath: in case of UITableView
                // Because -setContentOffset: may not work properly when using self-sizing cells
                if let tableView = self as? UITableView {
                    let numSections = tableView.numberOfSections
                    let lastSection = numSections - 1
                    let numRows = lastSection >= 0 ? tableView.numberOfRows(inSection: lastSection) : 0
                    let lastRow = numRows - 1
                    
                    if lastSection >= 0 && lastRow >= 0 {
                        let indexPath = IndexPath(row: lastRow, section: lastSection)
                        let scrollPos: UITableView.ScrollPosition = reveal ? .top : .bottom
                        
                        tableView.scrollToRow(at: indexPath, at: scrollPos, animated: true)
                        
                        // explicit return
                        return
                    }
                    
                    // setContentOffset: works fine for empty table view.
                }
                
                setContentOffset(CGPoint(x: self.contentOffset.x, y: reveal ? maxY : minY), animated: true)
            }
        } else {
            let minX = contentSize - self.bounds.size.width + pb_originalEndInset()
            let maxX = minX + indicatorRowSize
            
            if (self.contentOffset.x > minX && self.contentOffset.x < maxX) || force {
                setContentOffset(CGPoint(x: reveal ? maxX : minX, y: self.contentOffset.y), animated: true)
            }
        }
    }
    
    /**
     *  Set content inset with animation.
     *
     *  @param contentInset a new content inset
     *  @param animated     animate?
     *  @param completion   a completion block
     */
    private func pb_setScrollViewContentInset(_ contentInset: UIEdgeInsets,
                                              animated: Bool,
                                              completion: @escaping (Bool) -> Void) {
        if animated {
            UIView.animate(withDuration: kPBInfiniteScrollAnimationDuration,
                           delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState],
                           animations: {
                self.contentInset = contentInset
            }, completion: completion)
        } else {
            UIView.performWithoutAnimation {
                self.contentInset = contentInset
            }
            completion(true)
        }
    }
    
}
