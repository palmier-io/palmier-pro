#include "RetimeStretcher.h"

#include "third_party/signalsmith-stretch/signalsmith-stretch.h"

struct RetimeStretcher::Impl
{
    signalsmith::stretch::SignalsmithStretch<float> stretch;
};

RetimeStretcher::RetimeStretcher() : impl_(std::make_unique<Impl>())
{
}

RetimeStretcher::~RetimeStretcher() = default;

void RetimeStretcher::Configure(int32_t channels, double sampleRate)
{
    impl_->stretch.presetDefault(channels, static_cast<float>(sampleRate));
    impl_->stretch.setTransposeFactor(1.0f); // unity — retiming changes duration only, never pitch
}

void RetimeStretcher::Reset()
{
    impl_->stretch.reset();
}

int32_t RetimeStretcher::PrerollSampleFrames() const
{
    return impl_->stretch.blockSamples() + impl_->stretch.intervalSamples();
}

void RetimeStretcher::Seek(const float* inL, const float* inR, int32_t inputCount, double playbackRate)
{
    const float* const inputs[2] = { inL, inR };
    impl_->stretch.seek(inputs, inputCount, playbackRate);
}

void RetimeStretcher::Process(const float* inL, const float* inR, int32_t inputCount,
    float* outL, float* outR, int32_t outputCount)
{
    const float* const inputs[2] = { inL, inR };
    float* const outputs[2] = { outL, outR };
    impl_->stretch.process(inputs, inputCount, outputs, outputCount);
}
