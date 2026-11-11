// Renders the MiniDisc figure (MiniDisc-figure.html) as SwiftMD's 1024 px app icon.
// Usage: swift render-icon.swift MiniDisc-figure.html AppIcon.png
import AppKit
import WebKit

let args = CommandLine.arguments
let page = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let size: CGFloat = 1024

let setup = """
ui.st.xr = 0; Object.assign(ui.st, { open: false, sh: 0, spin: 0 });
setCam(15, 22);
document.documentElement.classList.add('nolabels'); ui.render();
document.querySelectorAll('#fig .tag').forEach(t => t.remove());
const svg = document.getElementById('fig'), b = document.getElementById('art').getBBox(), pad = 4;
svg.setAttribute('viewBox', `${b.x - pad} ${b.y - pad} ${b.width + 2*pad} ${b.height + 2*pad}`);
svg.removeAttribute('style'); svg.removeAttribute('class');
const art = svg.outerHTML;
document.head.querySelectorAll('style').forEach(s => s.remove());
document.body.removeAttribute('class');
document.body.innerHTML = `<style>
html, body { margin: 0; background: transparent; width: 1024px; height: 1024px; overflow: hidden; }
#tile { position: absolute; left: 100px; top: 100px; width: 824px; height: 824px; border-radius: 185px;
  background: radial-gradient(circle at 30% 22%, #fffaf0 0%, #f6ecff 55%, #e6d4f7 100%);
  box-shadow: inset 0 0 0 5px #231e1622, 0 10px 22px #3a245526; overflow: hidden; }
#tile svg { position: absolute; left: 22px; top: 30px; width: 760px; height: 770px; }
</style><div id="tile">${art}</div>`;
'ok'
"""

final class Renderer: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size, height: size), styleMask: .borderless, backing: .buffered, defer: false)

    func start() {
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        window.contentView = web
        window.orderBack(nil)
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            webView.evaluateJavaScript(setup) { _, error in
                if let error { print("setup failed: \(error)"); exit(1) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.snapshot() }
            }
        }
    }

    func snapshot() {
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: size, height: size)
        web.takeSnapshot(with: config) { image, error in
            guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
                print("snapshot failed: \(String(describing: error))"); exit(1)
            }
            // Redraw at exactly 1024 x 1024 pixels.
            let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
            rep.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
            NSGraphicsContext.restoreGraphicsState()
            try! out.representation(using: .png, properties: [:])!.write(to: output)
            print("wrote \(output.path)")
            exit(0)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = Renderer()
renderer.start()
app.run()
