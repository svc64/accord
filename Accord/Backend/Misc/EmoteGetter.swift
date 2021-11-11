//
// EmoteGetter.swift
// NitrolessMac
//
// Created by e b on 12.02.21
//

import SwiftUI
import AppKit

final class Counter: ObservableObject {
    var timer: Timer?

    @Published var value: Int = 0
    @Published var setinterval: Double = 0 {
        didSet {
            print("[Accord] set")
            timer = Timer.scheduledTimer(withTimeInterval: setinterval, repeats: true) { _ in
                if self.setinterval != 0 {
                    self.value += 1
                }
            }
        }
    }

    init(interval: Double) {
        timer = Timer.scheduledTimer(withTimeInterval: setinterval, repeats: true) { _ in
            if self.setinterval != 0 {
                self.value += 1
            }
        }
    }
}


struct GifView: View {
    @Binding var url: String
    @State var currentImage: NSImage = NSImage()
    @State var animatedImages: [NSImage]? = []
    @State var counterValue: Int = 0
    @State var duration: Double = 0
    @State var setinterval: Double = 1
    @State var value: Int = 0
    @State var timer: Timer?
    var body: some View {
        ZStack {
            if animatedImages?.count == 0 {
                Image(nsImage: NSImage())
            } else {
                Image(nsImage: animatedImages?[value] ?? NSImage()).resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                currentImage = NSImage()

                Request().image(url: URL(string: url), to: nil) { image in
                    guard let gif = image as? Gif else { return }
                    animatedImages = gif.animatedImages
                    duration = Double(CFTimeInterval(gif.calculatedDuration ?? 0))
                    setinterval = Double(duration / Double(animatedImages?.count ?? 1))
                    print(Double(duration / Double(animatedImages?.count ?? 1)))
                    self.timer = Timer.scheduledTimer(withTimeInterval: Double(duration / Double(animatedImages?.count ?? 1)), repeats: true) { _ in
                        if self.setinterval != 0 {
                            print(value)
                            (self.value) += 1 % animatedImages!.count
                        }
                    }
                }
            }
        }
    }
}
