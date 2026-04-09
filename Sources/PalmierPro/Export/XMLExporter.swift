import Foundation

/// Exports a timeline as XMEML 4 (FCP7 XML) — compatible with DaVinci Resolve, Premiere Pro, Final Cut Pro.
enum XMLExporter {

    static func export(timeline: Timeline, resolver: MediaResolver, outputURL: URL) {
        let fps = timeline.fps
        let width = timeline.width
        let height = timeline.height
        var emittedFiles = Set<String>()

        let videoImageTracks = timeline.tracks.filter { $0.type == .video || $0.type == .image }
        let audioTracks = timeline.tracks.filter { $0.type == .audio }

        // FCP XML: first <track> = bottom layer, last = top
        let videoTracksXml = videoImageTracks.reversed().map { track in
            buildVideoTrack(track, fps: fps, width: width, height: height, resolver: resolver, emittedFiles: &emittedFiles)
        }.joined(separator: "\n")

        let audioTracksXml = audioTracks.map { track in
            buildAudioTrack(track, fps: fps, resolver: resolver, emittedFiles: &emittedFiles)
        }.joined(separator: "\n")

        let xml = """
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
                    <width>\(width)</width>
                    <height>\(height)</height>
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
        \(audioTracksXml)
              </audio>
            </media>
          </sequence>
        </xmeml>
        """

        try? xml.data(using: .utf8)?.write(to: outputURL)
    }

    // MARK: - Track builders

    private static func buildVideoTrack(
        _ track: Track, fps: Int, width: Int, height: Int,
        resolver: MediaResolver, emittedFiles: inout Set<String>
    ) -> String {
        let sorted = track.clips.sorted { $0.startFrame < $1.startFrame }
        let clips = sorted.compactMap { clip -> String? in
            guard resolver.resolveURL(for: clip.mediaRef) != nil else { return nil }
            let name = resolver.displayName(for: clip.mediaRef)
            let fileXml = buildFileElement(clip.mediaRef, type: track.type, fps: fps, sourceDuration: clip.sourceDurationFrames, resolver: resolver, emittedFiles: &emittedFiles)
            let speedXml = buildSpeedXml(clip.speed)
            let filtersXml = buildVideoFilters(clip, seqWidth: width, seqHeight: height)
            return clipItemXml(
                id: clip.id, name: name, sourceDuration: clip.sourceDurationFrames, fps: fps,
                start: clip.startFrame, end: clip.endFrame,
                inPt: clip.trimStartFrame, outPt: clip.trimStartFrame + clip.durationFrames,
                inner: fileXml + speedXml + filtersXml
            )
        }.joined(separator: "\n")

        return """
                <track>
                  <enabled>\(track.hidden ? "FALSE" : "TRUE")</enabled>
                  <locked>FALSE</locked>
        \(clips)
                </track>
        """
    }

    private static func buildAudioTrack(
        _ track: Track, fps: Int,
        resolver: MediaResolver, emittedFiles: inout Set<String>
    ) -> String {
        let sorted = track.clips.sorted { $0.startFrame < $1.startFrame }
        let clips = sorted.compactMap { clip -> String? in
            guard resolver.resolveURL(for: clip.mediaRef) != nil else { return nil }
            let name = resolver.displayName(for: clip.mediaRef)
            let fileXml = buildFileElement(clip.mediaRef, type: .audio, fps: fps, sourceDuration: clip.sourceDurationFrames, resolver: resolver, emittedFiles: &emittedFiles)
            let speedXml = buildSpeedXml(clip.speed)
            let volumeXml = buildVolumeFilter(clip.volume)
            return clipItemXml(
                id: clip.id, name: name, sourceDuration: clip.sourceDurationFrames, fps: fps,
                start: clip.startFrame, end: clip.endFrame,
                inPt: clip.trimStartFrame, outPt: clip.trimStartFrame + clip.durationFrames,
                inner: fileXml + speedXml + volumeXml
            )
        }.joined(separator: "\n")

        return """
                <track>
                  <enabled>\(track.muted ? "FALSE" : "TRUE")</enabled>
                  <locked>FALSE</locked>
        \(clips)
                </track>
        """
    }

    // MARK: - Clip & file elements

    private static func clipItemXml(
        id: String, name: String, sourceDuration: Int, fps: Int,
        start: Int, end: Int, inPt: Int, outPt: Int, inner: String
    ) -> String {
        """
                  <clipitem id="clipitem-\(esc(id))">
                    <name>\(esc(name))</name>
                    <enabled>TRUE</enabled>
                    <duration>\(sourceDuration)</duration>
                    <rate>
                      <timebase>\(fps)</timebase>
                      <ntsc>FALSE</ntsc>
                    </rate>
                    <start>\(start)</start>
                    <end>\(end)</end>
                    <in>\(inPt)</in>
                    <out>\(outPt)</out>
        \(inner)
                  </clipitem>
        """
    }

    private static func buildFileElement(
        _ mediaRef: String, type: ClipType, fps: Int, sourceDuration: Int,
        resolver: MediaResolver, emittedFiles: inout Set<String>
    ) -> String {
        let fileId = "file-\(mediaRef)"
        if emittedFiles.contains(mediaRef) {
            return "            <file id=\"\(esc(fileId))\"/>"
        }
        emittedFiles.insert(mediaRef)

        let pathUrl: String
        if let url = resolver.resolveURL(for: mediaRef) {
            pathUrl = url.absoluteString
        } else {
            pathUrl = "media/\(mediaRef)"
        }

        let isAudio = type == .audio
        let mediaSec = isAudio ? """
                        <audio>
                          <samplecharacteristics>
                            <samplerate>48000</samplerate>
                            <depth>16</depth>
                            <samplesize>16</samplesize>
                          </samplecharacteristics>
                          <channelcount>2</channelcount>
                        </audio>
            """ : """
                        <video>
                          <samplecharacteristics>
                            <width>1920</width>
                            <height>1080</height>
                          </samplecharacteristics>
                        </video>
            """

        return """
                    <file id="\(esc(fileId))">
                      <name>\(esc(mediaRef))</name>
                      <pathurl>\(esc(pathUrl))</pathurl>
                      <rate>
                        <timebase>\(fps)</timebase>
                        <ntsc>FALSE</ntsc>
                      </rate>
                      <duration>\(sourceDuration)</duration>
                      <media>
            \(mediaSec)
                      </media>
                    </file>
            """
    }

    // MARK: - Filters

    private static func buildSpeedXml(_ speed: Double) -> String {
        guard speed != 1.0 else { return "" }
        return """

                    <speed>
                      <enabled>TRUE</enabled>
                      <rate>\(speed)</rate>
                    </speed>
            """
    }

    private static func buildVolumeFilter(_ volume: Double) -> String {
        guard volume != 1.0 else { return "" }
        let db = volume <= 0 ? -96.0 : 20.0 * log10(volume)
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
                          <value>\(String(format: "%.2f", db))</value>
                        </parameter>
                      </effect>
                    </filter>
            """
    }

    private static func buildVideoFilters(_ clip: Clip, seqWidth: Int, seqHeight: Int) -> String {
        let opacity = clip.opacity
        let t = clip.transform
        let cx = (t.x + t.width / 2.0 - 0.5) * Double(seqWidth)
        let cy = -((t.y + t.height / 2.0 - 0.5) * Double(seqHeight))

        let needsCenter = abs(cx) > 0.1 || abs(cy) > 0.1
        guard needsCenter || opacity != 1.0 else { return "" }

        var params = ""
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

    // MARK: - Helpers

    private static func esc(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
           .replacingOccurrences(of: "'", with: "&apos;")
    }
}
