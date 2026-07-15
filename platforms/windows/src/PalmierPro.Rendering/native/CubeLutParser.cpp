#include "CubeLutParser.h"

#include <algorithm>
#include <cctype>
#include <fstream>
#include <optional>
#include <sstream>

namespace
{
    std::string Trim(const std::string& s)
    {
        size_t b = s.find_first_not_of(" \t\r\n");
        if (b == std::string::npos)
        {
            return "";
        }
        size_t e = s.find_last_not_of(" \t\r\n");
        return s.substr(b, e - b + 1);
    }

    std::string Upper(const std::string& s)
    {
        std::string out = s;
        std::transform(out.begin(), out.end(), out.begin(), [](unsigned char c) { return static_cast<char>(std::toupper(c)); });
        return out;
    }

    std::vector<std::string> SplitWs(const std::string& s)
    {
        std::istringstream iss(s);
        std::vector<std::string> parts;
        std::string tok;
        while (iss >> tok)
        {
            parts.push_back(tok);
        }
        return parts;
    }

    std::optional<float> ParseFloat(const std::string& s)
    {
        try
        {
            size_t consumed = 0;
            float f = std::stof(s, &consumed);
            if (consumed != s.size())
            {
                return std::nullopt;
            }
            return f;
        }
        catch (...)
        {
            return std::nullopt;
        }
    }
}

bool CubeLutParser::Parse(const std::string& text, CubeLut& outLut)
{
    int dimension = 0;
    float domainMin[3] = {0, 0, 0};
    float domainMax[3] = {1, 1, 1};
    std::vector<float> values;

    std::istringstream stream(text);
    std::string rawLine;
    while (std::getline(stream, rawLine))
    {
        std::string line = Trim(rawLine);
        if (line.empty() || line[0] == '#')
        {
            continue;
        }
        std::vector<std::string> parts = SplitWs(line);
        if (parts.empty())
        {
            continue;
        }
        std::string first = Upper(parts[0]);
        if (first == "TITLE")
        {
            continue;
        }
        if (first == "LUT_1D_SIZE")
        {
            return false; // 1D LUTs are not supported here, matching LUTLoader.swift
        }
        if (first == "LUT_3D_SIZE")
        {
            if (parts.size() < 2)
            {
                return false;
            }
            try
            {
                dimension = std::stoi(parts.back());
            }
            catch (...)
            {
                return false;
            }
            continue;
        }
        if (first == "DOMAIN_MIN" || first == "DOMAIN_MAX")
        {
            if (parts.size() < 4)
            {
                return false;
            }
            float* target = first == "DOMAIN_MIN" ? domainMin : domainMax;
            for (int i = 0; i < 3; ++i)
            {
                auto f = ParseFloat(parts[1 + i]);
                if (!f)
                {
                    return false;
                }
                target[i] = *f;
            }
            continue;
        }
        // Data line: "r g b" (extra trailing tokens ignored, matching LUTLoader's `prefix(3)`).
        if (parts.size() < 3)
        {
            continue;
        }
        for (int i = 0; i < 3; ++i)
        {
            auto f = ParseFloat(parts[i]);
            if (!f)
            {
                return false;
            }
            values.push_back(*f);
        }
    }

    if (dimension <= 1 || dimension > 128)
    {
        return false;
    }
    size_t expected = static_cast<size_t>(dimension) * dimension * dimension * 3;
    if (values.size() != expected)
    {
        return false;
    }

    CubeLut lut;
    lut.dimension = dimension;
    lut.rgba.reserve(expected / 3 * 4);
    for (size_t i = 0; i < values.size() / 3; ++i)
    {
        for (int c = 0; c < 3; ++c)
        {
            float span = std::max(0.0001f, domainMax[c] - domainMin[c]);
            float v = (values[i * 3 + c] - domainMin[c]) / span;
            v = std::min(1.0f, std::max(0.0f, v));
            lut.rgba.push_back(v);
        }
        lut.rgba.push_back(1.0f);
    }

    outLut = std::move(lut);
    return true;
}

bool CubeLutParser::ParseFile(const std::string& path, CubeLut& outLut, std::string& outError)
{
    std::ifstream file(path, std::ios::in | std::ios::binary);
    if (!file)
    {
        outError = "cannot open .cube file: " + path;
        return false;
    }
    std::ostringstream ss;
    ss << file.rdbuf();
    if (!Parse(ss.str(), outLut))
    {
        outError = "invalid .cube file: " + path;
        return false;
    }
    return true;
}
