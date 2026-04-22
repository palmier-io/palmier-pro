import Foundation

/// Exports a timeline as XMEML 4 (FCP7 XML) — compatible with Premiere Pro, DaVinci Resolve, Final Cut Pro.
enum XMLExporter {

    static func export(timeline: Timeline, resolver: MediaResolver, outputURL: URL) {
        let xml = Builder(timeline: timeline, resolver: resolver).build()
        try? xml.data(using: .utf8)?.write(to: outputURL)
    }

    // MARK: - Builder

    private final class Builder {
        private let timeline: Timeline
        private let resolver: MediaResolver
        private let fps: Int
        private let seqWidth: Int
        private let seqHeight: Int

        /// Files already emitted in full; repeat references collapse to `<file id="..."/>`.
        private var emittedFiles: Set<FileKey> = []

        /// Clip id → position within its media type, used to emit `<link>` cross-references.
        private var clipAddresses: [String: ClipAddress] = [:]

        private var clipsByLinkGroup: [String: [Clip]] = [:]

        private struct FileKey: Hashable {
            let mediaRef: String
            let isAudio: Bool
        }

        private struct ClipAddress {
            let trackIndex: Int   // 1-based
            let clipIndex: Int    // 1-based
            let isAudio: Bool
        }

        init(timeline: Timeline, resolver: MediaResolver) {
            self.timeline = timeline
            self.resolver = resolver
            self.fps = timeline.fps
            self.seqWidth = timeline.width
            self.seqHeight = timeline.height
        }

        func build() -> String {
            // FCP XML orders video tracks bottom→top; our model stores them top→bottom.
            let videoTracks = Array(timeline.tracks.filter { $0.type.isVisual }.reversed())
            let audioTracks = timeline.tracks.filter { $0.type == .audio }

            let sortedVideo = videoTracks.map { sortEmittable($0) }
            let sortedAudio = audioTracks.map { sortEmittable($0) }
            indexAddresses(sortedVideo, isAudio: false)
            indexAddresses(sortedAudio, isAudio: true)
            indexLinkGroups()

            let videoTracksXml = zip(videoTracks, sortedVideo)
                .map { buildTrack($0.0, sortedClips: $0.1, isAudio: false) }
                .joined(separator: "\n")
            let audioTracksXml = zip(audioTracks, sortedAudio)
                .map { buildTrack($0.0, sortedClips: $0.1, isAudio: true) }
                .joined(separator: "\n")

            return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE xmeml>
            <xmeml version="4">
              <sequence id="sequence-1">
                <name>Timeline Export</name>
                <duration>\(timeline.totalFrames)</duration>
                <rate>
                  <timebase>\(fps)</timebase>
                  <ntsc>FALSE</ntsc>
                </rate>
                <timecode>
                  <rate>
                    <timebase>\(fps)</timebase>
                    <ntsc>FALSE</ntsc>
                  </rate>
                  <string>00:00:00:00</string>
                  <frame>0</frame>
                  <source>source</source>
                  <displayformat>NDF</displayformat>
                </timecode>
                <media>
                  <video>
                    <format>
                      <samplecharacteristics>
                        <width>\(seqWidth)</width>
                        <height>\(seqHeight)</height>
                        <anamorphic>FALSE</anamorphic>
                        <pixelaspectratio>square</pixelaspectratio>
                        <fielddominance>none</fielddominance>
                        <rate>
                          <timebase>\(fps)</timebase>
                          <ntsc>FALSE</ntsc>
                        </rate>
                      </samplecharacteristics>
                    </format>
            \(videoTracksXml)
                  </video>
                  <audio>
                    <numOutputChannels>2</numOutputChannels>
                    <format>
                      <samplecharacteristics>
                        <samplerate>48000</samplerate>
                        <depth>16</depth>
                      </samplecharacteristics>
                    </format>
                    <outputs>
                      <group>
                        <index>1</index>
                        <numchannels>2</numchannels>
                        <downmix>0</downmix>
                        <channel>
                          <index>1</index>
                        </channel>
                        <channel>
                          <index>2</index>
                        </channel>
                      </group>
                    </outputs>
            \(audioTracksXml)
                  </audio>
                </media>
              </sequence>
            </xmeml>
            """
        }

        // MARK: - Indexing

        /// Drops unresolvable clips here so track builders and `<link>` indices agree.
        private func sortEmittable(_ track: Track) -> [Clip] {
            track.clips
                .filter { resolver.resolveURL(for: $0.mediaRef) != nil }
                .sorted { $0.startFrame < $1.startFrame }
        }

        private func indexAddresses(_ sortedTracks: [[Clip]], isAudio: Bool) {
            for (ti, clips) in sortedTracks.enumerated() {
                for (ci, clip) in clips.enumerated() {
                    clipAddresses[clip.id] = ClipAddress(trackIndex: ti + 1, clipIndex: ci + 1, isAudio: isAudio)
                }
            }
        }

        private func indexLinkGroups() {
            for track in timeline.tracks {
                for clip in track.clips {
                    guard let group = clip.linkGroupId else { continue }
                    clipsByLinkGroup[group, default: []].append(clip)
                }
            }
        }

        // MARK: - Tracks

        private func buildTrack(_ track: Track, sortedClips: [Clip], isAudio: Bool) -> String {
            let enabled = isAudio ? !track.muted : !track.hidden
            let body = sortedClips.map { clip -> String in
                let mediaFilter = isAudio ? buildVolumeFilter(clip.volume) : buildVideoFilters(clip)
                let inner = buildFileElement(for: clip.mediaRef, isAudio: isAudio)
                    + buildTimeRemapFilter(speed: clip.speed, isAudio: isAudio)
                    + mediaFilter
                    + buildLinks(for: clip)
                return clipItemXml(clip: clip, isAudio: isAudio, inner: inner)
            }.joined(separator: "\n")

            return """
                    <track>
                      <enabled>\(enabled ? "TRUE" : "FALSE")</enabled>
                      <locked>FALSE</locked>
            \(body)
                    </track>
            """
        }

        // MARK: - Clipitem

        private func clipItemXml(clip: Clip, isAudio: Bool, inner: String) -> String {
            let name = resolver.displayName(for: clip.mediaRef)
            let sourceDuration = sourceDurationFrames(for: clip.mediaRef) ?? clip.sourceDurationFrames
            // <in>/<out> are source-frame offsets, so use sourceFramesConsumed (not the
            // timeline durationFrames). The Time Remap filter handles the rate conversion.
            let inPt = clip.trimStartFrame
            let outPt = clip.trimStartFrame + clip.sourceFramesConsumed
            return """
                      <clipitem id="clipitem-\(esc(clip.id))">
                        <masterclipid>\(esc(masterclipId(for: clip, isAudio: isAudio)))</masterclipid>
                        <name>\(esc(name))</name>
                        <enabled>TRUE</enabled>
                        <duration>\(sourceDuration)</duration>
                        <rate>
                          <timebase>\(fps)</timebase>
                          <ntsc>FALSE</ntsc>
                        </rate>
                        <start>\(clip.startFrame)</start>
                        <end>\(clip.endFrame)</end>
                        <in>\(inPt)</in>
                        <out>\(outPt)</out>
            \(inner)
                      </clipitem>
            """
        }

        private func masterclipId(for clip: Clip, isAudio: Bool) -> String {
            if let group = clip.linkGroupId {
                return "masterclip-\(group)"
            }
            return "masterclip-\(clip.mediaRef)-\(isAudio ? "audio" : "video")"
        }

        // MARK: - File elements

        /// Separate ids per media type — Premiere rejects an audio clipitem pointing at a
        /// file whose `<media>` only declares video characteristics, and vice versa.
        private func buildFileElement(for mediaRef: String, isAudio: Bool) -> String {
            let fileId = "file-\(mediaRef)-\(isAudio ? "audio" : "video")"
            let key = FileKey(mediaRef: mediaRef, isAudio: isAudio)
            if emittedFiles.contains(key) {
                return """

                        <file id="\(esc(fileId))"/>
            """
            }
            emittedFiles.insert(key)

            let entry = resolver.entry(for: mediaRef)
            let pathUrl = resolver.resolveURL(for: mediaRef)?.absoluteString ?? "media/\(mediaRef)"
            let name = entry?.name ?? mediaRef
            let durationFrames = entry.map { max(0, secondsToFrame(seconds: $0.duration, fps: fps)) } ?? 0

            let mediaSec: String
            if isAudio {
                mediaSec = """
                            <audio>
                              <samplecharacteristics>
                                <samplerate>48000</samplerate>
                                <depth>16</depth>
                              </samplecharacteristics>
                              <channelcount>2</channelcount>
                            </audio>
            """
            } else {
                let w = entry?.sourceWidth ?? seqWidth
                let h = entry?.sourceHeight ?? seqHeight
                mediaSec = """
                            <video>
                              <samplecharacteristics>
                                <width>\(w)</width>
                                <height>\(h)</height>
                                <anamorphic>FALSE</anamorphic>
                                <pixelaspectratio>square</pixelaspectratio>
                                <fielddominance>none</fielddominance>
                                <rate>
                                  <timebase>\(fps)</timebase>
                                  <ntsc>FALSE</ntsc>
                                </rate>
                              </samplecharacteristics>
                            </video>
            """
            }

            return """

                        <file id="\(esc(fileId))">
                          <name>\(esc(name))</name>
                          <pathurl>\(esc(pathUrl))</pathurl>
                          <rate>
                            <timebase>\(fps)</timebase>
                            <ntsc>FALSE</ntsc>
                          </rate>
                          <duration>\(durationFrames)</duration>
                          <media>
            \(mediaSec)
                          </media>
                        </file>
            """
        }

        private func sourceDurationFrames(for mediaRef: String) -> Int? {
            guard let seconds = resolver.entry(for: mediaRef)?.duration else { return nil }
            return max(0, secondsToFrame(seconds: seconds, fps: fps))
        }

        // MARK: - Links

        /// Partners share a linkGroupId; emitting a `<link>` per partner lets Premiere
        /// rebuild the A/V pair on import.
        private func buildLinks(for clip: Clip) -> String {
            guard let group = clip.linkGroupId,
                  let partners = clipsByLinkGroup[group],
                  partners.count > 1 else { return "" }

            return partners.compactMap { partner -> String? in
                guard let addr = clipAddresses[partner.id] else { return nil }
                return """

                        <link>
                          <linkclipref>clipitem-\(esc(partner.id))</linkclipref>
                          <mediatype>\(addr.isAudio ? "audio" : "video")</mediatype>
                          <trackindex>\(addr.trackIndex)</trackindex>
                          <clipindex>\(addr.clipIndex)</clipindex>
                        </link>
            """
            }.joined()
        }

        // MARK: - Filters

        /// Premiere doesn't infer speed from the `<in>`/`<out>` vs `<start>`/`<end>` ratio —
        /// without this filter, fast clips trim and slow clips black-pad.
        private func buildTimeRemapFilter(speed: Double, isAudio: Bool) -> String {
            guard speed != 1.0 else { return "" }
            let pct = speed * 100
            return """

                        <filter>
                          <effect>
                            <name>Time Remap</name>
                            <effectid>timeremap</effectid>
                            <effecttype>motion</effecttype>
                            <mediatype>\(isAudio ? "audio" : "video")</mediatype>
                            <parameter>
                              <parameterid>variablespeed</parameterid>
                              <name>variablespeed</name>
                              <valuemin>0</valuemin>
                              <valuemax>1</valuemax>
                              <value>0</value>
                            </parameter>
                            <parameter>
                              <parameterid>speed</parameterid>
                              <name>speed</name>
                              <valuemin>-100000</valuemin>
                              <valuemax>100000</valuemax>
                              <value>\(String(format: "%.4f", pct))</value>
                            </parameter>
                            <parameter>
                              <parameterid>reverse</parameterid>
                              <name>reverse</name>
                              <value>FALSE</value>
                            </parameter>
                            <parameter>
                              <parameterid>frameblending</parameterid>
                              <name>frameblending</name>
                              <value>FALSE</value>
                            </parameter>
                          </effect>
                        </filter>
            """
        }

        private func buildVolumeFilter(_ volume: Double) -> String {
            guard volume != 1.0 else { return "" }
            // FCP7 Audio Levels `level` is linear (1 = 0 dB, ~3.98 = +12 dB); out-of-range
            // values silence the clip in Premiere.
            let level = max(0, min(volume, 3.98))
            return """

                        <filter>
                          <effect>
                            <name>Audio Levels</name>
                            <effectid>audiolevels</effectid>
                            <effecttype>audio</effecttype>
                            <mediatype>audio</mediatype>
                            <parameter>
                              <parameterid>level</parameterid>
                              <name>Level</name>
                              <valuemin>0</valuemin>
                              <valuemax>3.98107</valuemax>
                              <value>\(String(format: "%.4f", level))</value>
                            </parameter>
                          </effect>
                        </filter>
            """
        }

        private func buildVideoFilters(_ clip: Clip) -> String {
            let opacity = clip.opacity
            let t = clip.transform
            let cx = (t.x + t.width / 2.0 - 0.5) * Double(seqWidth)
            let cy = -((t.y + t.height / 2.0 - 0.5) * Double(seqHeight))

            // Basic Motion `scale` is 100% = 1:1 source pixels, so a source larger than
            // the sequence zooms in. Translate Palmier's "fill the canvas" transform into
            // an explicit uniform percentage. FCP7 has no non-uniform scale — X wins.
            let scalePct: Double
            if let sw = resolver.entry(for: clip.mediaRef)?.sourceWidth, sw > 0 {
                scalePct = (Double(seqWidth) / Double(sw)) * t.width * 100
            } else {
                scalePct = t.width * 100
            }

            let needsCenter = abs(cx) > 0.1 || abs(cy) > 0.1
            let needsScale = abs(scalePct - 100) > 0.1
            guard needsCenter || needsScale || opacity != 1.0 else { return "" }

            var params = ""
            if needsScale {
                params += """

                            <parameter>
                              <parameterid>scale</parameterid>
                              <name>Scale</name>
                              <valuemin>0</valuemin>
                              <valuemax>1000</valuemax>
                              <value>\(String(format: "%.2f", scalePct))</value>
                            </parameter>
                """
            }
            if needsCenter {
                params += """

                            <parameter>
                              <parameterid>center</parameterid>
                              <name>Center</name>
                              <value>
                                <horiz>\(String(format: "%.1f", cx))</horiz>
                                <vert>\(String(format: "%.1f", cy))</vert>
                              </value>
                            </parameter>
                """
            }
            if opacity != 1.0 {
                params += """

                            <parameter>
                              <parameterid>opacity</parameterid>
                              <name>Opacity</name>
                              <value>\(String(format: "%.1f", opacity * 100))</value>
                            </parameter>
                """
            }

            return """

                        <filter>
                          <effect>
                            <name>Basic Motion</name>
                            <effectid>basic</effectid>
                            <effecttype>motion</effecttype>
                            <mediatype>video</mediatype>\(params)
                          </effect>
                        </filter>
            """
        }

        // MARK: - Escape

        private func esc(_ str: String) -> String {
            str.replacingOccurrences(of: "&", with: "&amp;")
               .replacingOccurrences(of: "<", with: "&lt;")
               .replacingOccurrences(of: ">", with: "&gt;")
               .replacingOccurrences(of: "\"", with: "&quot;")
               .replacingOccurrences(of: "'", with: "&apos;")
        }
    }
}
