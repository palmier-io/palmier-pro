#include "./common.h"

#ifndef SIGNALSMITH_DSP_DELAY_H
#define SIGNALSMITH_DSP_DELAY_H

#include <vector>
#include <array>
#include <cmath> // for std::ceil()
#include <type_traits>

#include <complex>
#include "./fft.h"
#include "./windows.h"

namespace signalsmith {
namespace delay {
	/**	@defgroup Delay Delay utilities
		@brief Standalone templated classes for delays
		
		You can set up a `Buffer` or `MultiBuffer`, and get interpolated samples using a `Reader` (separately on each channel in the multi-channel case) - or you can use `Delay`/`MultiDelay` which include their own buffers.

		Interpolation quality is chosen using a template class, from @ref Interpolators.

		@{
		@file
	*/

	/** @brief Single-channel delay buffer
 
		Access is used with `buffer[]`, relative to the internal read/write position ("head").  This head is moved using `++buffer` (or `buffer += n`), such that `buffer[1] == (buffer + 1)[0]` in a similar way iterators/pointers.
		
		Operations like `buffer - 10` or `buffer++` return a View, which holds a fixed position in the buffer (based on the read/write position at the time).
		
		The capacity includes both positive and negative indices.  For example, a capacity of 100 would support using any of the ranges:
		
		* `buffer[-99]` to buffer[0]`
		* `buffer[-50]` to buffer[49]`
		* `buffer[0]` to buffer[99]`

		Although buffers are usually used with historical samples accessed using negative indices e.g. `buffer[-10]`, you could equally use it flipped around (moving the head backwards through the buffer using `--buffer`).
	*/
	template<typename Sample>
	class Buffer {
		unsigned bufferIndex;
		unsigned bufferMask;
		std::vector<Sample> buffer;
	public:
		Buffer(int minCapacity=0) {
			resize(minCapacity);
		}
		// We shouldn't accidentally copy a delay buffer
		Buffer(const Buffer &other) = delete;
		Buffer & operator =(const Buffer &other) = delete;
		// But moving one is fine
		Buffer(Buffer &&other) = default;
		Buffer & operator =(Buffer &&other) = default;

		void resize(int minCapacity, Sample value=Sample()) {
			int bufferLength = 1;
			while (bufferLength < minCapacity) bufferLength *= 2;
			buffer.assign(bufferLength, value);
			bufferMask = unsigned(bufferLength - 1);
			bufferIndex = 0;
		}
		void reset(Sample value=Sample()) {
			buffer.assign(buffer.size(), value);
		}

		/// Holds a view for a particular position in the buffer
		template<bool isConst>
		class View {
			using CBuffer = typename std::conditional<isConst, const Buffer, Buffer>::type;
			using CSample = typename std::conditional<isConst, const Sample, Sample>::type;
			CBuffer *buffer = nullptr;
			unsigned bufferIndex = 0;
		public:
			View(CBuffer &buffer, int offset=0) : buffer(&buffer), bufferIndex(buffer.bufferIndex + (unsigned)offset) {}
			View(const View &other, int offset=0) : buffer(other.buffer), bufferIndex(other.bufferIndex + (unsigned)offset) {}
			View & operator =(const View &other) {
				buffer = other.buffer;
				bufferIndex = other.bufferIndex;
				return *this;
			}
			
			CSample & operator[](int offset) {
				return buffer->buffer[(bufferIndex + (unsigned)offset)&buffer->bufferMask];
			}
			const Sample & operator[](int offset) const {
				return buffer->buffer[(bufferIndex + (unsigned)offset)&buffer->bufferMask];
			}

			/// Write data into the buffer
			template<typename Data>
			void write(Data &&data, int length) {
				for (int i = 0; i < length; ++i) {
					(*this)[i] = data[i];
				}
			}
			/// Read data out from the buffer
			template<typename Data>
			void read(int length, Data &&data) const {
				for (int i = 0; i < length; ++i) {
					data[i] = (*this)[i];
				}
			}

			View operator +(int offset) const {
				return View(*this, offset);
			}
			View operator -(int offset) const {
				return View(*this, -offset);
			}
		};
		using MutableView = View<false>;
		using ConstView = View<true>;
		
		MutableView view(int offset=0) {
			return MutableView(*this, offset);
		}
		ConstView view(int offset=0) const {
			return ConstView(*this, offset);
		}
		ConstView constView(int offset=0) const {
			return ConstView(*this, offset);
		}

		Sample & operator[](int offset) {
			return buffer[(bufferIndex + (unsigned)offset)&bufferMask];
		}
		const Sample & operator[](int offset) const {
			return buffer[(bufferIndex + (unsigned)offset)&bufferMask];
		}

		/// Write data into the buffer
		template<typename Data>
		void write(Data &&data, int length) {
			for (int i = 0; i < length; ++i) {
				(*this)[i] = data[i];
			}
		}
		/// Read data out from the buffer
		template<typename Data>
		void read(int length, Data &&data) const {
			for (int i = 0; i < length; ++i) {
				data[i] = (*this)[i];
			}
		}
		
		Buffer & operator ++() {
			++bufferIndex;
			return *this;
		}
		Buffer & operator +=(int i) {
			bufferIndex += (unsigned)i;
			return *this;
		}
		Buffer & operator --() {
			--bufferIndex;
			return *this;
		}
		Buffer & operator -=(int i) {
			bufferIndex -= (unsigned)i;
			return *this;
		}

		MutableView operator ++(int) {
			MutableView view(*this);
			++bufferIndex;
			return view;
		}
		MutableView operator +(int i) {
			return MutableView(*this, i);
		}
		ConstView operator +(int i) const {
			return ConstView(*this, i);
		}
		MutableView operator --(int) {
			MutableView view(*this);
			--bufferIndex;
			return view;
		}
		MutableView operator -(int i) {
			return MutableView(*this, -i);
		}
		ConstView operator -(int i) const {
			return ConstView(*this, -i);
		}
	};

	/** @brief Multi-channel delay buffer

		This behaves similarly to the single-channel `Buffer`, with the following differences:
		
		* `buffer[c]` returns a view for a single channel, which behaves like the single-channel `Buffer::View`.
		* The constructor and `.resize()` take an additional first `channel` argument.
	*/
	template<typename Sample>
	class MultiBuffer {
		int channels, stride;
		Buffer<Sample> buffer;
	public:
		using ConstChannel = typename Buffer<Sample>::ConstView;
		using MutableChannel = typename Buffer<Sample>::MutableView;

		MultiBuffer(int channels=0, int capacity=0) : channels(channels), stride(capacity), buffer(channels*capacity) {}

		void resize(int nChannels, int capacity, Sample value=Sample()) {
			channels = nChannels;
			stride = capacity;
			buffer.resize(channels*capacity, value);
		}
		void reset(Sample value=Sample()) {
			buffer.reset(value);
		}

		/// A reference-like multi-channel result for a particular sample index
		template<bool isConst>
		class Stride {
			using CChannel = typename std::conditional<isConst, ConstChannel, MutableChannel>::type;
			using CSample = typename std::conditional<isConst, const Sample, Sample>::type;
			CChannel view;
			int channels, stride;
		public:
			Stride(CChannel view, int channels, int stride) : view(view), channels(channels), stride(stride) {}
			Stride(const Stride &other) : view(other.view), channels(other.channels), stride(other.stride) {}
			
			CSample & operator[](int channel) {
				return view[channel*stride];
			}
			const Sample & operator[](int channel) const {
				return view[channel*stride];
			}

			/// Reads from the buffer into a multi-channel result
			template<class Data>
			void get(Data &&result) const {
				for (int c = 0; c < channels; ++c) {
					result[c] = view[c*stride];
				}
			}
			/// Writes from multi-channel data into the buffer
			template<class Data>
			void set(Data &&data) {
				for (int c = 0; c < channels; ++c) {
					view[c*stride] = data[c];
				}
			}
			template<class Data>
			Stride & operator =(const Data &data) {
				set(data);
				return *this;
			}
			Stride & operator =(const Stride &data) {
				set(data);
				return *this;
			}
		};
		
		Stride<false> at(int offset) {
			return {buffer.view(offset), channels, stride};
		}
		Stride<true> at(int offset) const {
			return {buffer.view(offset), channels, stride};
		}

		/// Holds a particular position in the buffer
		template<bool isConst>
		class View {
			using CChannel = typename std::conditional<isConst, ConstChannel, MutableChannel>::type;
			CChannel view;
			int channels, stride;
		public:
			View(CChannel view, int channels, int stride) : view(view), channels(channels), stride(stride) {}
			
			CChannel operator[](int channel) {
				return view + channel*stride;
			}
			ConstChannel operator[](int channel) const {
				return view + channel*stride;
			}

			Stride<isConst> at(int offset) {
				return {view + offset, channels, stride};
			}
			Stride<true> at(int offset) const {
				return {view + offset, channels, stride};
			}
		};
		using MutableView = View<false>;
		using ConstView = View<true>;

		MutableView view(int offset=0) {
			return MutableView(buffer.view(offset), channels, stride);
		}
		ConstView view(int offset=0) const {
			return ConstView(buffer.view(offset), channels, stride);
		}
		ConstView constView(int offset=0) const {
			return ConstView(buffer.view(offset), channels, stride);
		}

		MutableChannel operator[](int channel) {
			return buffer + channel*stride;
		}
		ConstChannel operator[](int channel) const {
			return buffer + channel*stride;
		}
		
		MultiBuffer & operator ++() {
			++buffer;
			return *this;
		}
		MultiBuffer & operator +=(int i) {
			buffer += i;
			return *this;
		}
		MutableView operator ++(int) {
			return MutableView(buffer++, channels, stride);
		}
		MutableView operator +(int i) {
			return MutableView(buffer + i, channels, stride);
		}
		ConstView operator +(int i) const {
			return ConstView(buffer + i, channels, stride);
		}
		MultiBuffer & operator --() {
			--buffer;
			return *this;
		}
		MultiBuffer & operator -=(int i) {
			buffer -= i;
			return *this;
		}
		MutableView operator --(int) {
			return MutableView(buffer--, channels, stride);
		}
		MutableView operator -(int i) {
			return MutableView(buffer - i, channels, stride);
		}
		ConstView operator -(int i) const {
			return ConstView(buffer - i, channels, stride);
		}
	};
	
	/** \defgroup Interpolators Interpolators
		\ingroup Delay
		@{ */
	/// Nearest-neighbour interpolator
	/// \diagram{delay-random-access-nearest.svg,aliasing and maximum amplitude/delay errors for different input frequencies}
	template<typename Sample>
	struct InterpolatorNearest {
		static constexpr int inputLength = 1;
		static constexpr Sample latency = -0.5; // Because we're truncating, which rounds down too often
	
		template<class Data>
		static Sample fractional(const Data &data, Sample) {
			return data[0];
		}
	};
	/// Linear interpolator
	/// \diagram{delay-random-access-linear.svg,aliasing and maximum amplitude/delay errors for different input frequencies}
	template<typename Sample>
	struct InterpolatorLinear {
		static constexpr int inputLength = 2;
		static constexpr int latency = 0;
	
		template<class Data>
		static Sample fractional(const Data &data, Sample fractional) {
			Sample a = data[0], b = data[1];
			return a + fractional*(b - a);
		}
	};
	/// Spline cubic interpolator
	/// \diagram{delay-random-access-cubic.svg,aliasing and maximum amplitude/delay errors for different input frequencies}
	template<typename Sample>
	struct InterpolatorCubic {
		static constexpr int inputLength = 4;
		static constexpr int latency = 1;
	
		template<class Data>
		static Sample fractional(const Data &data, Sample fractional) {
			// Cubic interpolation
			Sample a = data[0], b = data[1], c = data[2], d = data[3];
			Sample cbDiff = c - b;
			Sample k1 = (c - a)*0.5;
			Sample k3 = k1 + (d - b)*0.5 - cbDiff*2;
			Sample k2 = cbDiff - k3 - k1;
			return b + fractional*(k1 + fractional*(k2 + fractional*k3)); // 16 ops total, not including the indexing
		}
	};

	// Efficient Algorithms and Structures for Fractional Delay Filtering Based on Lagrange Interpolation
	// Franck 2009 https://www.aes.org/e-lib/browse.cfm?elib=14647
	namespace _franck_impl {
		template<typename Sample, int n, int low, int high>
		struct ProductRange {
			using Array = std::array<Sample, (n + 1)>;
			static constexpr int mid = (low + high)/2;
			using Left = ProductRange<Sample, n, low, mid>;
			using Right = ProductRange<Sample, n, mid + 1, high>;

			Left left;
			Right right;

			const Sample total;
			ProductRange(Sample x) : left(x), right(x), total(left.total*right.total) {}

			template<class Data>
			Sample calculateResult(Sample extraFactor, const Data &data, const Array &invFactors) {
				return left.calculateResult(extraFactor*right.total, data, invFactors)
					+ right.calculateResult(extraFactor*left.total, data, invFactors);
			}
		};
		template<typename Sample, int n, int index>
		struct ProductRange<Sample, n, index, index> {
			using Array = std::array<Sample, (n + 1)>;

			const Sample total;
			ProductRange(Sample x) : total(x - index) {}

			template<class Data>
			Sample calculateResult(Sample extraFactor, const Data &data, const Array &invFactors) {
				return extraFactor*data[index]*invFactors[index];
			}
		};
	}
	/** Fixed-order Lagrange interpolation.
	\diagram{interpolator-LagrangeN.svg,aliasing and amplitude/delay errors for different sizes}
	*/
	template<typename Sample, int n>
	struct InterpolatorLagrangeN {
		static constexpr int inputLength = n + 1;
		static constexpr int latency = (n - 1)/2;

		using Array = std::array<Sample, (n + 1)>;
		Array invDivisors;

		InterpolatorLagrangeN() {
			for (int j = 0; j <= n; ++j) {
				double divisor = 1;
				for (int k = 0; k < j; ++k) divisor *= (j - k);
				for (int k = j + 1; k <= n; ++k) divisor *= (j - k);
				invDivisors[j] = 1/divisor;
			}
		}

		template<class Data>
		Sample fractional(const Data &data, Sample fractional) const {
			constexpr int mid = n/2;
			using Left = _franck_impl::ProductRange<Sample, n, 0, mid>;
			using Right = _franck_impl::ProductRange<Sample, n, mid + 1, n>;

			Sample x = fractional + latency;

			Left left(x);
			Right right(x);

			return left.calculateResult(right.total, data, invDivisors) + right.calculateResult(left.total, data, invDivisors);
		}
	};
	template<typename Sample>
	using InterpolatorLagrange3 = InterpolatorLagrangeN<Sample, 3>;
	template<typename Sample>
	using InterpolatorLagrange7 = InterpolatorLagrangeN<Sample, 7>;
	template<typename Sample>
	using InterpolatorLagrange19 = InterpolatorLagrangeN<Sample, 19>;

	/** Fixed-size Kaiser-windowed sinc interpolation.
	\diagram{interpolator-KaiserSincN.svg,aliasing and amplitude/delay errors for different sizes}
	If `minimumPhase` is enabled, a minimum-phase version of the kernel is used:
	\diagram{interpolator-KaiserSincN-min.svg,aliasing and amplitude/delay errors for minimum-phase mode}
	*/
	template<typename Sample, int n, bool minimumPhase=false>
	struct InterpolatorKaiserSincN {
		static constexpr int inputLength = n;
		static constexpr Sample latency = minimumPhase ? 0 : (n*Sample(0.5) - 1);

		int subSampleSteps;
		std::vector<Sample> coefficients;
		
		InterpolatorKaiserSincN() : InterpolatorKaiserSincN(0.5 - 0.45/std::sqrt(n)) {}
		InterpolatorKaiserSincN(double passFreq) : InterpolatorKaiserSincN(passFreq, 1 - passFreq) {}
		InterpolatorKaiserSincN(double passFreq, double stopFreq) {
			subSampleSteps = 2*n; // Heuristic again.  Really it depends on the bandwidth as well.
			double kaiserBandwidth = (stopFreq - passFreq)*(n + 1.0/subSampleSteps);
			kaiserBandwidth += 1.25/kaiserBandwidth; // We want to place the first zero, but (because using this to window a sinc essentially integrates it in the freq-domain), our ripples (and therefore zeroes) are out of phase.  This is a heuristic fix.
			double sincScale = M_PI*(passFreq + stopFreq);

			double centreIndex = n*subSampleSteps*0.5, scaleFactor = 1.0/subSampleSteps;
			std::vector<Sample> windowedSinc(subSampleSteps*n + 1);
			
			::signalsmith::windows::Kaiser::withBandwidth(kaiserBandwidth, false).fill(windowedSinc, windowedSinc.size());

			for (size_t i = 0; i < windowedSinc.size(); ++i) {
				double x = (i - centreIndex)*scaleFactor;
				int intX = std::round(x);
				if (intX != 0 && std::abs(x - intX) < 1e-6) {
					// Exact 0s
					windowedSinc[i] = 0;
				} else if (std::abs(x) > 1e-6) {
					double p = x*sincScale;
					windowedSinc[i] *= std::sin(p)/p;
				}
			}
			
			if (minimumPhase) {
				signalsmith::fft::FFT<Sample> fft(windowedSinc.size()*2, 1);
				windowedSinc.resize(fft.size(), 0);
				std::vector<std::complex<Sample>> spectrum(fft.size());
				std::vector<std::complex<Sample>> cepstrum(fft.size());
				fft.fft(windowedSinc, spectrum);
				for (size_t i = 0; i < fft.size(); ++i) {
					spectrum[i] = std::log(std::abs(spectrum[i]) + 1e-30);
				}
				fft.fft(spectrum, cepstrum);
				for (size_t i = 1; i < fft.size()/2; ++i) {
					cepstrum[i] *= 0;
				}
				for (size_t i = fft.size()/2 + 1; i < fft.size(); ++i) {
					cepstrum[i] *= 2;
				}
				Sample scaling = Sample(1)/fft.size();
				fft.ifft(cepstrum, spectrum);

				for (size_t i = 0; i < fft.size(); ++i) {
					Sample phase = spectrum[i].imag()*scaling;
					Sample mag = std::exp(spectrum[i].real()*scaling);
					spectrum[i] = {mag*std::cos(phase), mag*std::sin(phase)};
				}
				fft.ifft(spectrum, cepstrum);
				windowedSinc.resize(subSampleSteps*n + 1);
				windowedSinc.shrink_to_fit();
				for (size_t i = 0; i < windowedSinc.size(); ++i) {
					windowedSinc[i] = cepstrum[i].real()*scaling;
				}
			}
			
			// Re-order into FIR fractional-delay blocks
			coefficients.resize(n*(subSampleSteps + 1));
			for (int k = 0; k <= subSampleSteps; ++k) {
				for (int i = 0; i < n; ++i) {
					coefficients[k*n + i] = windowedSinc[(subSampleSteps - k) + i*subSampleSteps];
				}
			}
		}
		
		template<class Data>
		Sample fractional(const Data &data, Sample fractional) const {
			Sample subSampleDelay = fractional*subSampleSteps;
			int lowIndex = subSampleDelay;
			if (lowIndex >= subSampleSteps) lowIndex = subSampleSteps - 1;
			Sample subSampleFractional = subSampleDelay - lowIndex;
			int highIndex = lowIndex + 1;
			
			Sample sumLow = 0, sumHigh = 0;
			const Sample *coeffLow = coefficients.data() + lowIndex*n;
			const Sample *coeffHigh = coefficients.data() + highIndex*n;
			for (int i = 0; i < n; ++i) {
				sumLow += data[i]*coeffLow[i];
				sumHigh += data[i]*coeffHigh[i];
			}
			return sumLow + (sumHigh - sumLow)*subSampleFractional;
		}
	};

	template<typename Sample>
	using InterpolatorKaiserSinc20 = InterpolatorKaiserSincN<Sample, 20>;
	template<typename Sample>
	using InterpolatorKaiserSinc8 = InterpolatorKaiserSincN<Sample, 8>;
	template<typename Sample>
	using InterpolatorKaiserSinc4 = InterpolatorKaiserSincN<Sample, 4>;

	template<typename Sample>
	using InterpolatorKaiserSinc20Min = InterpolatorKaiserSincN<Sample, 20, true>;
	template<typename Sample>
	using InterpolatorKaiserSinc8Min = InterpolatorKaiserSincN<Sample, 8, true>;
	template<typename Sample>
	using InterpolatorKaiserSinc4Min = InterpolatorKaiserSincN<Sample, 4, true>;
	///  @}
	
	/** @brief A delay-line reader which uses an external buffer
 
		This is useful if you have multiple delay-lines reading from the same buffer.
	*/
	template<class Sample, template<typename> class Interpolator=InterpolatorLinear>
	class Reader : public Interpolator<Sample> /* so we can get the empty-base-class optimisation */ {
		using Super = Interpolator<Sample>;
	public:
		Reader () {}
		/// Pass in a configured interpolator
		Reader (const Interpolator<Sample> &interpolator) : Super(interpolator) {}
	
		template<typename Buffer>
		Sample read(const Buffer &buffer, Sample delaySamples) const {
			int startIndex = delaySamples;
			Sample remainder = delaySamples - startIndex;
			
			// Delay buffers use negative indices, but interpolators use positive ones
			using View = decltype(buffer - startIndex);
			struct Flipped {
				 View view;
				 Sample operator [](int i) const {
					return view[-i];
				 }
			};
			return Super::fractional(Flipped{buffer - startIndex}, remainder);
		}
	};

	/**	@brief A single-channel delay-line containing its own buffer.*/
	template<class Sample, template<typename> class Interpolator=InterpolatorLinear>
	class Delay : private Reader<Sample, Interpolator> {
		using Super = Reader<Sample, Interpolator>;
		Buffer<Sample> buffer;
	public:
		static constexpr Sample latency = Super::latency;

		Delay(int capacity=0) : buffer(1 + capacity + Super::inputLength) {}
		/// Pass in a configured interpolator
		Delay(const Interpolator<Sample> &interp, int capacity=0) : Super(interp), buffer(1 + capacity + Super::inputLength) {}
		
		void reset(Sample value=Sample()) {
			buffer.reset(value);
		}
		void resize(int minCapacity, Sample value=Sample()) {
			buffer.resize(minCapacity + Super::inputLength, value);
		}
		
		/** Read a sample from `delaySamples` >= 0 in the past.
		The interpolator may add its own latency on top of this (see `Delay::latency`).  The default interpolation (linear) has 0 latency.
		*/
		Sample read(Sample delaySamples) const {
			return Super::read(buffer, delaySamples);
		}
		/// Writes a sample. Returns the same object, so that you can say `delay.write(v).read(delay)`.
		Delay & write(Sample value) {
			++buffer;
			buffer[0] = value;
			return *this;
		}
	};

	/**	@brief A multi-channel delay-line with its own buffer. */
	template<class Sample, template<typename> class Interpolator=InterpolatorLinear>
	class MultiDelay : private Reader<Sample, Interpolator> {
		using Super = Reader<Sample, Interpolator>;
		int channels;
		MultiBuffer<Sample> multiBuffer;
	public:
		static constexpr Sample latency = Super::latency;

		MultiDelay(int channels=0, int capacity=0) : channels(channels), multiBuffer(channels, 1 + capacity + Super::inputLength) {}

		void reset(Sample value=Sample()) {
			multiBuffer.reset(value);
		}
		void resize(int nChannels, int capacity, Sample value=Sample()) {
			channels = nChannels;
			multiBuffer.resize(channels, capacity + Super::inputLength, value);
		}
		
		/// A single-channel delay-line view, similar to a `const Delay`
		struct ChannelView {
			static constexpr Sample latency = Super::latency;

			const Super &reader;
			typename MultiBuffer<Sample>::ConstChannel channel;
			
			Sample read(Sample delaySamples) const {
				return reader.read(channel, delaySamples);
			}
		};
		ChannelView operator [](int channel) const {
			return ChannelView{*this, multiBuffer[channel]};
		}

		/// A multi-channel result, lazily calculating samples
		struct DelayView {
			Super &reader;
			typename MultiBuffer<Sample>::ConstView view;
			Sample delaySamples;
			
			// Calculate samples on-the-fly
			Sample operator [](int c) const {
				return reader.read(view[c], delaySamples);
			}
		};
		DelayView read(Sample delaySamples) {
			return DelayView{*this, multiBuffer.constView(), delaySamples};
		}
		/// Reads into the provided output structure
		template<class Output>
		void read(Sample delaySamples, Output &output) {
			for (int c = 0; c < channels; ++c) {
				output[c] = Super::read(multiBuffer[c], delaySamples);
			}
		}
		/// Reads separate delays for each channel
		template<class Delays, class Output>
		void readMulti(const Delays &delays, Output &output) {
			for (int c = 0; c < channels; ++c) {
				output[c] = Super::read(multiBuffer[c], delays[c]);
			}
		}
		template<class Data>
		MultiDelay & write(const Data &data) {
			++multiBuffer;
			for (int c = 0; c < channels; ++c) {
				multiBuffer[c][0] = data[c];
			}
			return *this;
		}
	};

/** @} */
}} // signalsmith::delay::
#endif // include guard
