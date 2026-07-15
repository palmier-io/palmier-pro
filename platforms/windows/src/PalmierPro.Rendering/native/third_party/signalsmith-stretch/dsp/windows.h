#include "./common.h"

#ifndef SIGNALSMITH_DSP_WINDOWS_H
#define SIGNALSMITH_DSP_WINDOWS_H

#include <cmath>
#include <algorithm>

namespace signalsmith {
namespace windows {
	/**	@defgroup Windows Window functions
		@brief Windows for spectral analysis
		
		These are generally double-precision, because they are mostly calculated during setup/reconfiguring, not real-time code.
		
		@{
		@file
	*/
	
	/** @brief The Kaiser window (almost) maximises the energy in the main-lobe compared to the side-lobes.
		
		Kaiser windows can be constructing using the shape-parameter (beta) or using the static `with???()` methods.*/
	class Kaiser {
		// I_0(x)=\sum_{k=0}^{N}\frac{x^{2k}}{(k!)^2\cdot4^k}
		inline static double bessel0(double x) {
			const double significanceLimit = 1e-4;
			double result = 0;
			double term = 1;
			double m = 0;
			while (term > significanceLimit) {
				result += term;
				++m;
				term *= (x*x)/(4*m*m);
			}

			return result;
		}
		double beta;
		double invB0;
		
		static double heuristicBandwidth(double bandwidth) {
			// Good peaks
			//return bandwidth + 8/((bandwidth + 3)*(bandwidth + 3));
			// Good average
			//return bandwidth + 14/((bandwidth + 2.5)*(bandwidth + 2.5));
			// Compromise
			return bandwidth + 8/((bandwidth + 3)*(bandwidth + 3)) + 0.25*std::max(3 - bandwidth, 0.0);
		}
	public:
		/// Set up a Kaiser window with a given shape.  `beta` is `pi*alpha` (since there is ambiguity about shape parameters)
		Kaiser(double beta) : beta(beta), invB0(1/bessel0(beta)) {}

		/// @name Bandwidth methods
		/// @{
		static Kaiser withBandwidth(double bandwidth, bool heuristicOptimal=false) {
			return Kaiser(bandwidthToBeta(bandwidth, heuristicOptimal));
		}

		/** Returns the Kaiser shape where the main lobe has the specified bandwidth (as a factor of 1/window-length).
		\diagram{kaiser-windows.svg,You can see that the main lobe matches the specified bandwidth.}
		If `heuristicOptimal` is enabled, the main lobe width is _slightly_ wider, improving both the peak and total energy - see `bandwidthToEnergyDb()` and `bandwidthToPeakDb()`.
		\diagram{kaiser-windows-heuristic.svg, The main lobe extends to ±bandwidth/2.} */
		static double bandwidthToBeta(double bandwidth, bool heuristicOptimal=false) {
			if (heuristicOptimal) { // Heuristic based on numerical search
				bandwidth = heuristicBandwidth(bandwidth);
			}
			bandwidth = std::max(bandwidth, 2.0);
			double alpha = std::sqrt(bandwidth*bandwidth*0.25 - 1);
			return alpha*M_PI;
		}
		
		static double betaToBandwidth(double beta) {
			double alpha = beta*(1.0/M_PI);
			return 2*std::sqrt(alpha*alpha + 1);
		}
		/// @}

		/// @name Performance methods
		/// @{
		/** @brief Total energy ratio (in dB) between side-lobes and the main lobe.
			\diagram{windows-kaiser-sidelobe-energy.svg,Measured main/side lobe energy ratio.  You can see that the heuristic improves performance for all bandwidth values.}
			This function uses an approximation which is accurate to ±0.5dB for 2 ⩽ bandwidth ≤ 10, or 1 ⩽ bandwidth ≤ 10 when `heuristicOptimal`is enabled.
		*/
		static double bandwidthToEnergyDb(double bandwidth, bool heuristicOptimal=false) {
			// Horrible heuristic fits
			if (heuristicOptimal) {
				if (bandwidth < 3) bandwidth += (3 - bandwidth)*0.5;
				return 12.9 + -3/(bandwidth + 0.4) - 13.4*bandwidth + (bandwidth < 3)*-9.6*(bandwidth - 3);
			}
			return 10.5 + 15/(bandwidth + 0.4) - 13.25*bandwidth + (bandwidth < 2)*13*(bandwidth - 2);
		}
		static double energyDbToBandwidth(double energyDb, bool heuristicOptimal=false) {
			double bw = 1;
			while (bw < 20 && bandwidthToEnergyDb(bw, heuristicOptimal) > energyDb) {
				bw *= 2;
			}
			double step = bw/2;
			while (step > 0.0001) {
				if (bandwidthToEnergyDb(bw, heuristicOptimal) > energyDb) {
					bw += step;
				} else {
					bw -= step;
				}
				step *= 0.5;
			}
			return bw;
		}
		/** @brief Peak ratio (in dB) between side-lobes and the main lobe.
			\diagram{windows-kaiser-sidelobe-peaks.svg,Measured main/side lobe peak ratio.  You can see that the heuristic improves performance, except in the bandwidth range 1-2 where peak ratio was sacrificed to improve total energy ratio.}
			This function uses an approximation which is accurate to ±0.5dB for 2 ⩽ bandwidth ≤ 9, or 0.5 ⩽ bandwidth ≤ 9 when `heuristicOptimal`is enabled.
		*/
		static double bandwidthToPeakDb(double bandwidth, bool heuristicOptimal=false) {
			// Horrible heuristic fits
			if (heuristicOptimal) {
				return 14.2 - 20/(bandwidth + 1) - 13*bandwidth + (bandwidth < 3)*-6*(bandwidth - 3) + (bandwidth < 2.25)*5.8*(bandwidth - 2.25);
			}
			return 10 + 8/(bandwidth + 2) - 12.75*bandwidth + (bandwidth < 2)*4*(bandwidth - 2);
		}
		static double peakDbToBandwidth(double peakDb, bool heuristicOptimal=false) {
			double bw = 1;
			while (bw < 20 && bandwidthToPeakDb(bw, heuristicOptimal) > peakDb) {
				bw *= 2;
			}
			double step = bw/2;
			while (step > 0.0001) {
				if (bandwidthToPeakDb(bw, heuristicOptimal) > peakDb) {
					bw += step;
				} else {
					bw -= step;
				}
				step *= 0.5;
			}
			return bw;
		}
		/** @} */

		/** Equivalent noise bandwidth (ENBW), a measure of frequency resolution.
			\diagram{windows-kaiser-enbw.svg,Measured ENBW\, with and without the heuristic bandwidth adjustment.}
			This approximation is accurate to ±0.05 up to a bandwidth of 22.
		*/
		static double bandwidthToEnbw(double bandwidth, bool heuristicOptimal=false) {
			if (heuristicOptimal) bandwidth = heuristicBandwidth(bandwidth);
			double b2 = std::max<double>(bandwidth - 2, 0);
			return 1 + b2*(0.2 + b2*(-0.005 + b2*(-0.000005 + b2*0.0000022)));
		}

		/// Return the window's value for position in the range [0, 1]
		double operator ()(double unit) {
			double r = 2*unit - 1;
			double arg = std::sqrt(1 - r*r);
			return bessel0(beta*arg)*invB0;
		}
	
		/// Fills an arbitrary container with a Kaiser window
		template<typename Data>
		void fill(Data &&data, int size) const {
			double invSize = 1.0/size;
			for (int i = 0; i < size; ++i) {
				double r = (2*i + 1)*invSize - 1;
				double arg = std::sqrt(1 - r*r);
				data[i] = bessel0(beta*arg)*invB0;
			}
		}
	};

	/** @brief The Approximate Confined Gaussian window is (almost) optimal
		
		ACG windows can be constructing using the shape-parameter (sigma) or using the static `with???()` methods.*/
	class ApproximateConfinedGaussian {
		double gaussianFactor;
		
		double gaussian(double x) const {
			return std::exp(-x*x*gaussianFactor);
		}
	public:
		/// Heuristic map from bandwidth to the appropriately-optimal sigma
		static double bandwidthToSigma(double bandwidth) {
			return 0.3/std::sqrt(bandwidth);
		}
		static ApproximateConfinedGaussian withBandwidth(double bandwidth) {
			return ApproximateConfinedGaussian(bandwidthToSigma(bandwidth));
		}

		ApproximateConfinedGaussian(double sigma) : gaussianFactor(0.0625/(sigma*sigma)) {}
	
		/// Fills an arbitrary container
		template<typename Data>
		void fill(Data &&data, int size) const {
			double invSize = 1.0/size;
			double offsetScale = gaussian(1)/(gaussian(3) + gaussian(-1));
			double norm = 1/(gaussian(0) - 2*offsetScale*(gaussian(2)));
			for (int i = 0; i < size; ++i) {
				double r = (2*i + 1)*invSize - 1;
				data[i] = norm*(gaussian(r) - offsetScale*(gaussian(r - 2) + gaussian(r + 2)));
			}
		}
	};

	/** Forces STFT perfect-reconstruction (WOLA) on an existing window, for a given STFT interval.
	For example, here are perfect-reconstruction versions of the approximately-optimal @ref Kaiser windows:
	\diagram{kaiser-windows-heuristic-pr.svg,Note the lower overall energy\, and the pointy top for 2x bandwidth. Spectral performance is about the same\, though.}
	*/
	template<typename Data>
	void forcePerfectReconstruction(Data &&data, int windowLength, int interval) {
		for (int i = 0; i < interval; ++i) {
			double sum2 = 0;
			for (int index = i; index < windowLength; index += interval) {
				sum2 += data[index]*data[index];
			}
			double factor = 1/std::sqrt(sum2);
			for (int index = i; index < windowLength; index += interval) {
				data[index] *= factor;
			}
		}
	}

/** @} */
}} // signalsmith::windows
#endif // include guard
