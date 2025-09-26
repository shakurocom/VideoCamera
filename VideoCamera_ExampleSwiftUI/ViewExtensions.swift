import SwiftUI
import UIKit

@MainActor
public protocol PlatformView: View {
    var verticalSizeClass: UserInterfaceSizeClass? { get }
    var horizontalSizeClass: UserInterfaceSizeClass? { get }
    var isRegularSize: Bool { get }
    var isCompactSize: Bool { get }
}

public extension PlatformView {
    var isRegularSize: Bool { horizontalSizeClass == .regular && verticalSizeClass == .regular }
    var isCompactSize: Bool { horizontalSizeClass == .compact || verticalSizeClass == .compact }
}

/// A container view for the app's toolbars that lays the items out horizontally
/// on iPhone and vertically on iPad and Mac Catalyst.
public struct AdaptiveToolbar<Content: View>: PlatformView {

    @Environment(\.verticalSizeClass) public  var verticalSizeClass
    @Environment(\.horizontalSizeClass) public  var horizontalSizeClass

    private let horizontalSpacing: CGFloat
    private let verticalSpacing: CGFloat
    private let content: Content

    public init(horizontalSpacing: CGFloat = 0.0, verticalSpacing: CGFloat = 0.0, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    public var body: some View {
        if isRegularSize {
            VStack(spacing: verticalSpacing) { content }
        } else {
            HStack(spacing: horizontalSpacing) { content }
        }
    }
}

public struct DefaultButtonStyle: ButtonStyle {

    @Environment(\.isEnabled) private var isEnabled: Bool
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public enum Size: CGFloat {
        case small = 22
        case large = 24
    }

    private let size: Size

    public init(size: Size) {
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isEnabled ? .primary : Color(white: 0.4))
            .font(.system(size: size.rawValue))
        // Pad buttons on devices that use the `regular` size class,
        // and also when explicitly requesting large buttons.
            .padding(isRegularSize || size == .large ? 10.0 : 0)
            .background(.black.opacity(0.4))
            .clipShape(size == .small ? AnyShape(Rectangle()) : AnyShape(Circle()))
    }

    public var isRegularSize: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
    }

}

public extension View {

    func debugBorder(color: Color = .red) -> some View {
        self
            .border(color)
    }

}

public extension Image {

    init(_ image: CGImage) {
        self.init(uiImage: UIImage(cgImage: image))
    }

}
