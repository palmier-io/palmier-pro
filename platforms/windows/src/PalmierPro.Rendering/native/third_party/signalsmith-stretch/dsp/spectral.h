#include "./common.h"

#ifndef SIGNALSMITH_DSP_SPECTRAL_H
#define SIGNALSMITH_DSP_SPECTRAL_H

#include "./perf.h"
#include "./fft.h"
#include "./windows.h"
#include "./delay.h"

#include <cmath>

namespace signalsmith {
namespace spectral {
	/**	@defgroup Spectral Spectral Processing
		@brief Tools for frequency-domain manipulation of audio signals
		
		@{
		@file
	*/
	
	/** @brief An FFT with built-in windowing and round-trip scaling
	
		This uses a Modified Real FFT, which applies half-bin shift before the transform.  The result therefore has `N/2` bins, centred at the frequencies: `(i + 0.5)/N`.
		
		This avoids the awkward (real-valued) bands for DC-offset and Nyquist.
	 */
	template<typename Sample>
	class WindowedFFT {
		using MRFFT = signalsmith::fft::ModifiedRealFFT<Sample>;
		using Complex = std::complex<Sample>;
		MRFFT mrfft{2};

		std::vector<Sample> fftWindow;
		std::vector<Sample> timeBuffer;
		int offsetSamples = 0;
	public:
		/// Returns a fast FFT size <= `size`
		static int fastSizeAbove(int size, int divisor=1) {
			return MRFFT::fastSizeAbove(size/divisor)*divisor;
		}
		/// Returns a fast FFT size >= `size`
		static int fastSizeBelow(int size, int divisor=1) {
			return MRFFT::fastSizeBelow(1 + (size - 1)/divisor)*divisor;
		}

		WindowedFFT() {}
		WindowedFFT(int size, int rotateSamples=0) {
			setSize(size, rotateSamples);
		}
		template<class WindowFn>
		WindowedFFT(int size, WindowFn fn, Sample windowOffset=0.5, int rotateSamples=0) {
			setSize(size, fn, windowOffset, rotateSamples);
		}

		/// Sets the size, returning the window for modification (initially all 1s)
		std::vector<Sample> & setSizeWindow(int size, int rotateSamples=0) {
			mrfft.setSize(size);
			fftWindow.assign(size, 1);
			timeBuffer.resize(size);
			offsetSamples = rotateSamples;
			if (offsetSamples < 0) offsetSamples += size; // TODO: for a negative rotation, the other half of the result is inverted
			return fftWindow;
		}
		/// Sets the FFT size, with a user-defined functor for the window
		template<class WindowFn>
		void setSize(int size, WindowFn fn, Sample windowOffset=0.5, int rotateSamples=0) {
			setSizeWindow(size, rotateSamples);
		
			Sample invSize = 1/(Sample)size;
			for (int i = 0; i < size; ++i) {
				Sample r = (i + windowOffset)*invSize;
				fftWindow[i] = fn(r);
			}
		}
		/// Sets the size (using the default Blackman-Harris window)
		void setSize(int size, int rotateSamples=0) {
			setSize(size, [](double x) {
				double phase = 2*M_PI*x;
				// Blackman-Harris
				return 0.35875 - 0.48829*std::cos(phase) + 0.14128*std::cos(phase*2) - 0.01168*std::cos(phase*3);
			}, Sample(0.5), rotateSamples);
		}

		const std::vector<Sample> & window() const {
			return this->fftWindow;
		}
		int size() const {
			return mrfft.size();
		}
		
		/// Performs an FFT, with windowing and rotation (if enabled)
		template<bool withWindow=true, bool withScaling=false, class Input, class Output>
		void fft(Input &&input, Output &&output) {
			int fftSize = size();
			const Sample norm = (withScaling ? 1/(Sample)fftSize : 1);
			for (int i = 0; i < offsetSamples; ++i) {
				// Inverted polarity since we're using the MRFFT
				timeBuffer[i + fftSize - offsetSamples] = -input[i]*norm*(withWindow ? fftWindow[i] : Sample(1));
			}
			for (int i = offsetSamples; i < fftSize; ++i) {
				timeBuffer[i - offsetSamples] = input[i]*norm*(withWindow ? fftWindow[i] : Sample(1));
			}
			mrfft.fft(timeBuffer, output);
		}
		/// Performs an FFT (no windowing or rotation)
		template<class Input, class Output>
		void fftRaw(Input &&input, Output &&output) {
			mrfft.fft(input, output);
		}

		/// Inverse FFT, with windowing, 1/N scaling and rotation (if enabled)
		template<bool withWindow=true, bool withScaling=true, class Input, class Output>
		void ifft(Input &&input, Output &&output) {
			mrfft.ifft(input, timeBuffer);
			int fftSize = mrfft.size();
			const Sample norm = (withScaling ? 1/(Sample)fftSize : 1);

			for (int i = 0; i < offsetSamples; ++i) {
				// Inverted polarity since we're using the MRFFT
				output[i] = -timeBuffer[i + fftSize - offsetSamples]*norm*(withWindow ? fftWindow[i] : Sample(1));
			}
			for (int i = offsetSamples; i < fftSize; ++i) {
				output[i] = timeBuffer[i - offsetSamples]*norm*(withWindow ? fftWindow[i] : Sample(1));
			}
		}
		/// Performs an IFFT (no windowing, scaling or rotation)
		template<class Input, class Output>
		void ifftRaw(Input &&input, Output &&output) {
			mrfft.ifft(input, output);
		}
	};
	
	/** STFT synthesis, built on a `MultiBuffer`.
 
		Any window length and block interval is supported, but the FFT size may be rounded up to a faster size (by zero-padding).  It uses a heuristically-optimal Kaiser window modified for perfect-reconstruction.
		
		\diagram{stft-aliasing-simulated.svg,Simulated bad-case aliasing (random phase-shift for each band) for overlapping ratios}

		There is a "latest valid index", and you can read the output up to one `historyLength` behind this (see `.resize()`).  You can read up to one window-length _ahead_ to get partially-summed future output.
		
		\diagram{stft-buffer-validity.svg}
		
		You move the valid index along using `.ensureValid()`, passing in a functor which provides spectra (using `.analyse()` and/or direct modification through `.spectrum[c]`):

		\code
			void processSample(...) {
				stft.ensureValid([&](int) {
					// Here, we introduce (1 - windowSize) of latency
					stft.analyse(inputBuffer.view(1 - windowSize))
				});
				// read as a MultiBuffer
				auto result = stft.at(0);
				++stft; // also moves the latest valid index
			}

			void processBlock(...) {
				// assuming `historyLength` == blockSize
				stft.ensureValid(blockSize, [&](int blockStartIndex) {
					int inputStart = blockStartIndex + (1 - windowSize);
					stft.analyse(inputBuffer.view(inputStart));
				});
				auto earliestValid = stft.at(0);
				auto latestValid = stft.at(blockSize);
				stft += blockSize;
			}
		\endcode
		
		The index passed to this functor will be greater than the previous valid index, and `<=` the index you pass in.  Therefore, if you call `.ensureValid()` every sample, it can only ever be `0`.
	*/
	template<typename Sample>
	class STFT : public signalsmith::delay::MultiBuffer<Sample> {

		using Super = signalsmith::delay::MultiBuffer<Sample>;
		using Complex = std::complex<Sample>;

		int channels = 0, _windowSize = 0, _fftSize = 0, _interval = 1;
		int validUntilIndex = 0;

		class MultiSpectrum {
			int channels, stride;
			std::vector<Complex> buffer;
		public:
			MultiSpectrum() : MultiSpectrum(0, 0) {}
			MultiSpectrum(int channels, int bands) : channels(channels), stride(bands), buffer(channels*bands, 0) {}
			
			void resize(int nChannels, int nBands) {
				channels = nChannels;
				stride = nBands;
				buffer.assign(channels*stride, 0);
			}
			
			void reset() {
				buffer.assign(buffer.size(), 0);
			}
			
			void swap(MultiSpectrum &other) {
				using std::swap;
				swap(buffer, other.buffer);
			}

			Complex * operator [](int channel) {
				return buffer.data() + channel*stride;
			}
			const Complex * operator [](int channel) const {
				return buffer.data() + channel*stride;
			}
		};
		std::vector<Sample> timeBuffer;

		bool rotate = false;
		void resizeInternal(int newChannels, int windowSize, int newInterval, int historyLength, int zeroPadding) {
			Super::resize(newChannels,
				windowSize /* for output summing */
				+ newInterval /* so we can read `windowSize` ahead (we'll be at most `interval-1` from the most recent block */
				+ historyLength);

			int fftSize = fft.fastSizeAbove(windowSize + zeroPadding);

			this->channels = newChannels;
			_windowSize = windowSize;
			this->_fftSize = fftSize;
			this->_interval = newInterval;
			validUntilIndex = -1;
			
			setWindow(windowShape, rotate);

			spectrum.resize(channels, fftSize/2);
			timeBuffer.resize(fftSize);
		}
	public:
		enum class Window {kaiser, acg};
		/// \deprecated use `.setWindow()` which actually updates the window when you change it
		Window windowShape = Window::kaiser;
		// for convenience
		static constexpr Window kaiser = Window::kaiser;
		static constexpr Window acg = Window::acg;
		
		/** Swaps between the default (Kaiser) shape and Approximate Confined Gaussian (ACG).
		\diagram{stft-windows.svg,Default (Kaiser) windows and partial cumulative sum}
		The ACG has better rolloff since its edges go to 0:
		\diagram{stft-windows-acg.svg,ACG windows and partial cumulative sum}
		However, it generally has worse performance in terms of total sidelobe energy, affecting worst-case aliasing levels for (most) higher overlap ratios:
		\diagram{stft-aliasing-simulated-acg.svg,Simulated bad-case aliasing for ACG windows - compare with above}*/
		// TODO: these should both be set before resize()
		void setWindow(Window shape, bool rotateToZero=false) {
			windowShape = shape;
			rotate = rotateToZero;

			auto &window = fft.setSizeWindow(_fftSize, rotateToZero ? _windowSize/2 : 0);
			if (windowShape == Window::kaiser) {
				using Kaiser = ::signalsmith::windows::Kaiser;
				/// Roughly optimal Kaiser for STFT analysis (forced to perfect reconstruction)
				auto kaiser = Kaiser::withBandwidth(_windowSize/double(_interval), true);
				kaiser.fill(window, _windowSize);
			} else {
				using Confined = ::signalsmith::windows::ApproximateConfinedGaussian;
				auto confined = Confined::withBandwidth(_windowSize/double(_interval));
				confined.fill(window, _windowSize);
			}
			::signalsmith::windows::forcePerfectReconstruction(window, _windowSize, _interval);
			
			// TODO: fill extra bits of an input buffer with NaN/Infinity, to break this, and then fix by adding zero-padding to WindowedFFT (as opposed to zero-valued window sections)
			for (int i = _windowSize; i < _fftSize; ++i) {
				window[i] = 0;
			}
		}
		
		using Spectrum = MultiSpectrum;
		Spectrum spectrum;
		WindowedFFT<Sample> fft;
		
		STFT() {}
		/// Parameters passed straight to `.resize()`
		STFT(int channels, int windowSize, int interval, int historyLength=0, int zeroPadding=0) {
			resize(channels, windowSize, interval, historyLength, zeroPadding);
		}

		/// Sets the channel-count, FFT size and interval.
		void resize(int nChannels, int windowSize, int interval, int historyLength=0, int zeroPadding=0) {
			resizeInternal(nChannels, windowSize, interval, historyLength, zeroPadding);
		}
		
		int windowSize() const {
			return _windowSize;
		}
		int fftSize() const {
			return _fftSize;
		}
		int interval() const {
			return _interval;
		}
		/// Returns the (analysis and synthesis) window
		decltype(fft.window()) window() const {
			return fft.window();
		}
		/// Calculates the effective window for the partially-summed future output (relative to the most recent block)
		std::vector<Sample> partialSumWindow(bool includeLatestBlock=true) const {
			const auto &w = window();
			std::vector<Sample> result(_windowSize, 0);
			int firstOffset = (includeLatestBlock ? 0 : _interval);
			for (int offset = firstOffset; offset < _windowSize; offset += _interval) {
				for (int i = 0; i < _windowSize - offset; ++i) {
					Sample value = w[i + offset];
					result[i] += value*value;
				}
			}
			return result;
		}
		
		/// Resets everything - since we clear the output sum, it will take `windowSize` samples to get proper output.
		void reset() {
			Super::reset();
			spectrum.reset();
			validUntilIndex = -1;
		}
		
		/** Generates valid output up to the specified index (or 0), using the callback as many times as needed.
			
			The callback should be a functor accepting a single integer argument, which is the index for which a spectrum is required.
			
			The block created from these spectra will start at this index in the output, plus `.latency()`.
		*/
		template<class AnalysisFn>
		void ensureValid(int i, AnalysisFn fn) {
			while (validUntilIndex < i) {
				int blockIndex = validUntilIndex + 1;
				fn(blockIndex);

				auto output = this->view(blockIndex);
				for (int c = 0; c < channels; ++c) {
					auto channel = output[c];

					// Clear out the future sum, a window-length and an interval ahead
					for (int wi = _windowSize; wi < _windowSize + _interval; ++wi) {
						channel[wi] = 0;
					}

					// Add in the IFFT'd result
					fft.ifft(spectrum[c], timeBuffer);
					for (int wi = 0; wi < _windowSize; ++wi) {
						channel[wi] += timeBuffer[wi];
					}
				}
				validUntilIndex += _interval;
			}
		}
		/// The same as above, assuming index 0
		template<class AnalysisFn>
		void ensureValid(AnalysisFn fn) {
			return ensureValid(0, fn);
		}
		/// Returns the next invalid index (a.k.a. the index of the next block)
		int nextInvalid() const {
			return validUntilIndex + 1;
		}
		
		/** Analyse a multi-channel input, for any type where `data[channel][index]` returns samples
 
		Results can be read/edited using `.spectrum`. */
		template<class Data>
		void analyse(Data &&data) {
			for (int c = 0; c < channels; ++c) {
				fft.fft(data[c], spectrum[c]);
			}
		}
		template<class Data>
		void analyse(int c, Data &&data) {
			fft.fft(data, spectrum[c]);
		}
		/// Analyse without windowing or zero-rotation
		template<class Data>
		void analyseRaw(Data &&data) {
			for (int c = 0; c < channels; ++c) {
				fft.fftRaw(data[c], spectrum[c]);
			}
		}
		template<class Data>
		void analyseRaw(int c, Data &&data) {
			fft.fftRaw(data, spectrum[c]);
		}

		int bands() const {
			return _fftSize/2;
		}

		/** Internal latency (between the block-index requested in `.ensureValid()` and its position in the output)
 
		Currently unused, but it's in here to allow for a future implementation which spreads the FFT calculations out across each interval.*/
		int latency() {
			return 0;
		}
		
		// @name Shift the underlying buffer (moving the "valid" index accordingly)
		// @{
		STFT & operator ++() {
			Super::operator ++();
			validUntilIndex--;
			return *this;
		}
		STFT & operator +=(int i) {
			Super::operator +=(i);
			validUntilIndex -= i;
			return *this;
		}
		STFT & operator --() {
			Super::operator --();
			validUntilIndex++;
			return *this;
		}
		STFT & operator -=(int i) {
			Super::operator -=(i);
			validUntilIndex += i;
			return *this;
		}
		// @}

		typename Super::MutableView operator ++(int postIncrement) {
			auto result = Super::operator ++(postIncrement);
			validUntilIndex--;
			return result;
		}
		typename Super::MutableView operator --(int postIncrement) {
			auto result = Super::operator --(postIncrement);
			validUntilIndex++;
			return result;
		}
	};

	/** STFT processing, with input/output.
		Before calling `.ensureValid(index)`, you should make sure the input is filled up to `index`.
	*/
	template<typename Sample>
	class ProcessSTFT : public STFT<Sample> {
		using Super = STFT<Sample>;
	public:
		signalsmith::delay::MultiBuffer<Sample> input;
	
		ProcessSTFT(int inChannels, int outChannels, int windowSize, int interval, int historyLength=0) {
			resize(inChannels, outChannels, windowSize, interval, historyLength);
		}

		/** Alter the spectrum, using input up to this point, for the output block starting from this point.
			Sub-classes should replace this with whatever processing is desired. */
		virtual void processSpectrum(int /*blockIndex*/) {}
		
		/// Sets the input/output channels, FFT size and interval.
		void resize(int inChannels, int outChannels, int windowSize, int interval, int historyLength=0) {
			Super::resize(outChannels, windowSize, interval, historyLength);
			input.resize(inChannels, windowSize + interval + historyLength);
		}
		void reset(Sample value=Sample()) {
			Super::reset(value);
			input.reset(value);
		}

		/// Internal latency, including buffering samples for analysis.
		int latency() {
			return Super::latency() + (this->windowSize() - 1);
		}
		
		void ensureValid(int i=0) {
			Super::ensureValid(i, [&](int blockIndex) {
				this->analyse(input.view(blockIndex - this->windowSize() + 1));
				this->processSpectrum(blockIndex);
			});
		}

		// @name Shift the output, input, and valid index.
		// @{
		ProcessSTFT & operator ++() {
			Super::operator ++();
			++input;
			return *this;
		}
		ProcessSTFT & operator +=(int i) {
			Super::operator +=(i);
			input += i;
			return *this;
		}
		ProcessSTFT & operator --() {
			Super::operator --();
			--input;
			return *this;
		}
		ProcessSTFT & operator -=(int i) {
			Super::operator -=(i);
			input -= i;
			return *this;
		}
		// @}
	};

/** @} */
}} // signalsmith::spectral::
#endif // include guard
