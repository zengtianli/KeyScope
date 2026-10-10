import AppKit
import Foundation

let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
func round(_ rect: NSRect, _ radius: CGFloat, _ color: NSColor) {
    color.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
for (name, pixels) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let tr = AffineTransform(scale: CGFloat(pixels)/1024)
    (tr as NSAffineTransform).concat()
    let base = NSBezierPath(roundedRect: NSRect(x:52,y:52,width:920,height:920),xRadius:208,yRadius:208)
    NSGradient(starting: NSColor(srgbRed:0.26,green:0.45,blue:0.97,alpha:1),ending:NSColor(srgbRed:0.16,green:0.22,blue:0.62,alpha:1))!.draw(in:base,angle:-50)
    round(NSRect(x:142,y:374,width:616,height:390),76,NSColor(srgbRed:0.96,green:0.98,blue:1,alpha:1))
    let ink = NSColor(srgbRed:0.255,green:0.38,blue:0.773,alpha:1)
    for x in [199,306,413,520,627] { round(NSRect(x:x,y:629,width:78,height:74),16,ink) }
    for (x,w) in [(199,96),(324,78),(431,78),(538,78)] {round(NSRect(x:x,y:525,width:w,height:74),16,ink)}
    round(NSRect(x:252,y:433,width:310,height:56),16,ink)
    let mint = NSColor(srgbRed:0.663,green:0.965,blue:0.906,alpha:1)
    let handle = NSBezierPath(); handle.move(to: NSPoint(x:770,y:288));handle.line(to:NSPoint(x:856,y:200));handle.lineWidth=66;handle.lineCapStyle = .round;mint.setStroke();handle.stroke()
    let lens=NSBezierPath(ovalIn:NSRect(x:511,y:249,width:298,height:298));NSColor(srgbRed:0.16,green:0.26,blue:0.67,alpha:1).setFill();lens.fill();lens.lineWidth=44;mint.setStroke();lens.stroke()
    let check=NSBezierPath();check.move(to:NSPoint(x:599,y:398));check.line(to:NSPoint(x:643,y:354));check.line(to:NSPoint(x:726,y:442));check.lineWidth=29;check.lineCapStyle = .round;check.lineJoinStyle = .round;NSColor.white.setStroke();check.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:output).appendingPathComponent(name+".png"))
}
