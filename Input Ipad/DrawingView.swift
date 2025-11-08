
import SwiftUI
import PencilKit
import UIKit

// MARK: - Main SwiftUI Screen
struct DrawingView: View {
    // Tool state
    @State private var selectedTool: Tool = .pen
    @State private var inkColor: UIColor = .systemBlue
    @State private var width: CGFloat = 8
    @State private var fingerDraws: Bool = true

    // Zoom/transform state (purely visual)
    @State private var scale: CGFloat = 1.0
    @State private var rotation: CGFloat = 0.0
    @State private var translation: CGSize = .zero

    // Canvas binding handles
    @State private var canvasView = PKCanvasView()
    @State private var toolPicker = PKToolPicker()

    var body: some View {
        NavigationView {
            VStack(spacing: 8) {
                // Top controls
                controlsBar
                    .padding(.horizontal, 16)

                // Canvas
                CanvasRepresentable(
                    canvasView: $canvasView,
                    toolPicker: $toolPicker,
                    selectedTool: $selectedTool,
                    inkColor: $inkColor,
                    width: $width,
                    fingerDraws: $fingerDraws,
                    scale: $scale,
                    rotation: $rotation,
                    translation: $translation
                )
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .navigationTitle("Pencil + Pro Input")
        }
        .navigationViewStyle(.stack)
    }

    // MARK: Top bar UI
    private var controlsBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Picker("Tool", selection: $selectedTool) {
                    Text("Pen").tag(Tool.pen)
                    Text("Eraser").tag(Tool.eraser)
                }
                .pickerStyle(.segmented)

                ColorPicker("Color", selection: Binding(
                    get: { Color(inkColor) },
                    set: { newColor in
                        inkColor = UIColor(newColor)
                    }
                ))
                .labelsHidden()
                .disabled(selectedTool == .eraser)
            }

            HStack(spacing: 12) {
                Text("Width: \(Int(width))")
                    .font(.system(size: 14, weight: .medium))

                Slider(value: Binding(
                    get: { Double(width) },
                    set: { width = CGFloat($0) }
                ), in: 1...30, step: 1)
                .disabled(selectedTool == .eraser)

                Spacer(minLength: 8)

                Button("Undo") { canvasView.undoManager?.undo() }
                Button("Redo") { canvasView.undoManager?.redo() }
                Button("Clear") { canvasView.drawing = PKDrawing() }

                Toggle(isOn: $fingerDraws) {
                    Text("Finger draws")
                        .font(.system(size: 14))
                }
                .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                .frame(maxWidth: 220, alignment: .trailing)
            }
        }
    }
}

// MARK: - Tool enum
enum Tool: String, Hashable {
    case pen, eraser
}

// MARK: - UIViewRepresentable wrapper
struct CanvasRepresentable: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    @Binding var toolPicker: PKToolPicker

    @Binding var selectedTool: Tool
    @Binding var inkColor: UIColor
    @Binding var width: CGFloat
    @Binding var fingerDraws: Bool

    // Visual transforms
    @Binding var scale: CGFloat
    @Binding var rotation: CGFloat
    @Binding var translation: CGSize

    func makeUIView(context: Context) -> ContainerView {
        let container = ContainerView()
        container.backgroundColor = .clear

        // Create and embed our custom canvas subclass that supports key commands
        let keyCanvas = KeyCanvasView()
        keyCanvas.translatesAutoresizingMaskIntoConstraints = false
        keyCanvas.backgroundColor = .secondarySystemBackground
        keyCanvas.layer.cornerRadius = 12
        keyCanvas.layer.masksToBounds = true
        keyCanvas.delegate = context.coordinator
        keyCanvas.alwaysBounceHorizontal = false
        keyCanvas.alwaysBounceVertical = false
        if #available(iOS 14.0, *) {
            keyCanvas.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
        }

        // Keep a reference synchronized with SwiftUI state
        canvasView = keyCanvas

        container.addSubview(keyCanvas)
        NSLayoutConstraint.activate([
            keyCanvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            keyCanvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            keyCanvas.topAnchor.constraint(equalTo: container.topAnchor),
            keyCanvas.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        // Gestures: pinch, rotate, two-finger pan on container
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator
        container.addGestureRecognizer(pinch)

        let rotate = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRotate(_:)))
        rotate.delegate = context.coordinator
        container.addGestureRecognizer(rotate)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = context.coordinator
        container.addGestureRecognizer(pan)

        // ToolPicker integration
        if let window = container.window ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.keyWindow {

            toolPicker.addObserver(keyCanvas)
            toolPicker.setVisible(true, forFirstResponder: keyCanvas)
            keyCanvas.becomeFirstResponder()
            _ = window
        }

        // Connect key command callbacks
        context.coordinator.installKeyCommandCallbacks(on: keyCanvas)

        // Apply initial tool
        context.coordinator.applyCurrentTool()

        return container
    }

    func updateUIView(_ container: ContainerView, context: Context) {
        guard let keyCanvas = container.subviews.compactMap({ $0 as? KeyCanvasView }).first else { return }

        // Update input policy
        if #available(iOS 14.0, *) {
            keyCanvas.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
        }

        // Update tool whenever relevant state changes
        context.coordinator.applyCurrentTool()

        // Apply current transform
        var t = CGAffineTransform.identity
        t = t.translatedBy(x: translation.width, y: translation.height)
        t = t.rotated(by: rotation)
        t = t.scaledBy(x: scale, y: scale)
        keyCanvas.transform = t
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // Simple container so we can attach gestures without interfering with PKCanvasView itself
    final class ContainerView: UIView {}

    // MARK: - Coordinator
    final class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
        private let parent: CanvasRepresentable

        // For cumulative gestures
        private var baseScale: CGFloat = 1.0
        private var baseRotation: CGFloat = 0.0
        private var baseTranslation: CGSize = .zero

        init(_ parent: CanvasRepresentable) {
            self.parent = parent
        }

        // MARK: PKCanvasViewDelegate
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Integrate with undo automatically
        }

        // MARK: Tool application
        func applyCurrentTool() {
            let tool: PKTool
            switch parent.selectedTool {
            case .pen:
                tool = PKInkingTool(.pen, color: parent.inkColor, width: parent.width)
            case .eraser:
                tool = PKEraserTool(.vector)
            }
            parent.canvasView.tool = tool
        }

        // MARK: Gestures
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func handlePinch(_ gr: UIPinchGestureRecognizer) {
            switch gr.state {
            case .began:
                baseScale = parent.scale
            case .changed, .ended:
                let new = clamp(baseScale * gr.scale, min: 0.25, max: 4.0)
                parent.scale = new
            default:
                break
            }
        }

        @objc func handleRotate(_ gr: UIRotationGestureRecognizer) {
            switch gr.state {
            case .began:
                baseRotation = parent.rotation
            case .changed, .ended:
                parent.rotation = baseRotation + gr.rotation
            default:
                break
            }
        }

        @objc func handlePan(_ gr: UIPanGestureRecognizer) {
            switch gr.state {
            case .began:
                baseTranslation = parent.translation
            case .changed, .ended:
                let delta = gr.translation(in: gr.view)
                parent.translation = CGSize(width: baseTranslation.width + delta.x,
                                            height: baseTranslation.height + delta.y)
            default:
                break
            }
        }

        // MARK: Key commands wiring
        func installKeyCommandCallbacks(on keyCanvas: KeyCanvasView) {
            keyCanvas.onSelectPen = { [weak self] in
                guard let self = self else { return }
                self.parent.selectedTool = .pen
                self.applyCurrentTool()
            }
            keyCanvas.onSelectEraser = { [weak self] in
                guard let self = self else { return }
                self.parent.selectedTool = .eraser
                self.applyCurrentTool()
            }
            keyCanvas.onUndo = { [weak self] in
                self?.parent.canvasView.undoManager?.undo()
            }
            keyCanvas.onRedo = { [weak self] in
                self?.parent.canvasView.undoManager?.redo()
            }
            keyCanvas.onClear = { [weak self] in
                self?.parent.canvasView.drawing = PKDrawing()
            }
            keyCanvas.onZoomIn = { [weak self] in
                guard let self = self else { return }
                self.parent.scale = clamp(self.parent.scale * 1.15, min: 0.25, max: 4.0)
            }
            keyCanvas.onZoomOut = { [weak self] in
                guard let self = self else { return }
                self.parent.scale = clamp(self.parent.scale / 1.15, min: 0.25, max: 4.0)
            }
            keyCanvas.onResetTransform = { [weak self] in
                guard let self = self else { return }
                self.parent.scale = 1.0
                self.parent.rotation = 0.0
                self.parent.translation = .zero
            }
        }
    }
}

// MARK: - Custom PKCanvasView to support keyboard shortcuts
final class KeyCanvasView: PKCanvasView {
    // Callbacks bridged to SwiftUI
    var onSelectPen: (() -> Void)?
    var onSelectEraser: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onClear: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onResetTransform: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        return [
            // Tool switching
            UIKeyCommand(input: "1", modifierFlags: [], action: #selector(selectPen), discoverabilityTitle: "Pen"),
            UIKeyCommand(input: "2", modifierFlags: [], action: #selector(selectEraser), discoverabilityTitle: "Eraser"),
            // Undo/Redo
            UIKeyCommand(input: "z", modifierFlags: [.command], action: #selector(undoAction), discoverabilityTitle: "Undo"),
            UIKeyCommand(input: "Z", modifierFlags: [.command, .shift], action: #selector(redoAction), discoverabilityTitle: "Redo"),
            // Clear
            UIKeyCommand(input: "k", modifierFlags: [.command], action: #selector(clearCanvas), discoverabilityTitle: "Clear Canvas"),
            // Zoom
            UIKeyCommand(input: "=", modifierFlags: [.command], action: #selector(zoomIn), discoverabilityTitle: "Zoom In"),
            UIKeyCommand(input: "-", modifierFlags: [.command], action: #selector(zoomOut), discoverabilityTitle: "Zoom Out"),
            UIKeyCommand(input: "0", modifierFlags: [.command], action: #selector(resetTransform), discoverabilityTitle: "Actual Size")
        ]
    }

    @objc private func selectPen() { onSelectPen?() }
    @objc private func selectEraser() { onSelectEraser?() }
    @objc private func undoAction() { onUndo?() }
    @objc private func redoAction() { onRedo?() }
    @objc private func clearCanvas() { onClear?() }
    @objc private func zoomIn() { onZoomIn?() }
    @objc private func zoomOut() { onZoomOut?() }
    @objc private func resetTransform() { onResetTransform?() }
}

// MARK: - Utilities
fileprivate func clamp<T: Comparable>(_ value: T, min: T, max: T) -> T {
    Swift.max(min, Swift.min(max, value))
}


// MARK: - Preview
struct DrawingView_Previews: PreviewProvider {
    static var previews: some View {
        DrawingView()
            .previewInterfaceOrientation(.landscapeLeft)
    }
}
