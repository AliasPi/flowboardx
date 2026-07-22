#include "windows_handwriting_recognition_service.h"

#include <flutter/binary_messenger.h>
#include <flutter/standard_method_codec.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.UI.Input.Inking.h>
#include <winrt/base.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

constexpr char kChannelName[] = "de.flowboardx/handwriting_recognition";
constexpr UINT kRecognitionCompletedMessage = WM_APP + 0x46;
constexpr size_t kMaximumStrokes = 4096;
constexpr size_t kMaximumPoints = 250000;
constexpr double kMaximumAbsoluteCoordinate = 10000000.0;
constexpr uint32_t kMaximumBitmapDimension = 2048;
constexpr uint32_t kMaximumOcrHeight = 1024;
constexpr uint32_t kMinimumBitmapDimension = 128;
constexpr float kTargetInkHeight = 320.0f;
constexpr float kBitmapPadding = 48.0f;
constexpr int kStrokeRadius = 4;
constexpr size_t kMaximumRasterSteps = 8000000;

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using FlutterResult = flutter::MethodResult<EncodableValue>;
using InkPoint = winrt::Windows::Foundation::Point;
using namespace winrt::Windows::UI::Input::Inking;

// WinRT exposes bitmap pixels through this documented COM interop interface.
// It is declared locally because it is intentionally absent from the regular
// C++/WinRT projection headers.
struct __declspec(uuid("5B0D3235-4DBA-4D44-865D-BC5DCCF3A1E2"))
    IMemoryBufferByteAccess : ::IUnknown {
  virtual HRESULT __stdcall GetBuffer(uint8_t** value,
                                      uint32_t* capacity) = 0;
};

struct NativeResponse {
  bool success = false;
  EncodableValue value;
  std::string error_code;
  std::string error_message;
};

struct ChannelCompletion {
  std::shared_ptr<WindowsHandwritingRecognitionService::SharedState> state;
  std::unique_ptr<FlutterResult> result;
  NativeResponse response;
};

const EncodableValue* FindValue(const EncodableMap& map,
                                const std::string& key) {
  const auto iterator = map.find(EncodableValue(key));
  return iterator == map.end() ? nullptr : &iterator->second;
}

double ReadNumber(const EncodableValue& value) {
  if (const auto* number = std::get_if<double>(&value)) {
    return *number;
  }
  if (const auto* number = std::get_if<int32_t>(&value)) {
    return static_cast<double>(*number);
  }
  if (const auto* number = std::get_if<int64_t>(&value)) {
    return static_cast<double>(*number);
  }
  throw std::invalid_argument("coordinate is not numeric");
}

std::string ReadLanguageTag(const EncodableValue& arguments) {
  const auto* map = std::get_if<EncodableMap>(&arguments);
  if (map == nullptr) {
    return "de-DE";
  }
  const auto* value = FindValue(*map, "languageTag");
  if (value == nullptr) {
    return "de-DE";
  }
  const auto* tag = std::get_if<std::string>(value);
  if (tag == nullptr || tag->empty() || tag->size() > 64) {
    throw std::invalid_argument("invalid language tag");
  }
  return *tag;
}

std::vector<std::vector<InkPoint>> ReadStrokes(
    const EncodableValue& arguments) {
  const auto* request = std::get_if<EncodableMap>(&arguments);
  if (request == nullptr) {
    throw std::invalid_argument("request is not a map");
  }
  const auto* strokes_value = FindValue(*request, "strokes");
  const auto* raw_strokes = strokes_value == nullptr
                                ? nullptr
                                : std::get_if<EncodableList>(strokes_value);
  if (raw_strokes == nullptr || raw_strokes->empty() ||
      raw_strokes->size() > kMaximumStrokes) {
    throw std::invalid_argument("invalid stroke count");
  }

  std::vector<std::vector<InkPoint>> strokes;
  strokes.reserve(raw_strokes->size());
  size_t total_points = 0;
  for (const auto& raw_stroke : *raw_strokes) {
    const auto* stroke_map = std::get_if<EncodableMap>(&raw_stroke);
    if (stroke_map == nullptr) {
      throw std::invalid_argument("stroke is not a map");
    }
    const auto* points_value = FindValue(*stroke_map, "points");
    const auto* raw_points = points_value == nullptr
                                 ? nullptr
                                 : std::get_if<EncodableList>(points_value);
    if (raw_points == nullptr) {
      throw std::invalid_argument("points are missing");
    }
    if (raw_points->empty()) {
      continue;
    }
    if (raw_points->size() > kMaximumPoints - total_points) {
      throw std::invalid_argument("too many points");
    }

    std::vector<InkPoint> points;
    points.reserve(std::max<size_t>(raw_points->size(), 2));
    for (const auto& raw_point : *raw_points) {
      const auto* point_map = std::get_if<EncodableMap>(&raw_point);
      if (point_map == nullptr) {
        throw std::invalid_argument("point is not a map");
      }
      const auto* x_value = FindValue(*point_map, "x");
      const auto* y_value = FindValue(*point_map, "y");
      if (x_value == nullptr || y_value == nullptr) {
        throw std::invalid_argument("coordinate is missing");
      }
      const double x = ReadNumber(*x_value);
      const double y = ReadNumber(*y_value);
      if (!std::isfinite(x) || !std::isfinite(y) ||
          std::abs(x) > kMaximumAbsoluteCoordinate ||
          std::abs(y) > kMaximumAbsoluteCoordinate) {
        throw std::invalid_argument("coordinate is outside the safe range");
      }
      points.emplace_back(static_cast<float>(x), static_cast<float>(y));
    }
    // InkStrokeBuilder rejects a one-point polyline. Preserve taps as a tiny
    // segment; at board scale the added 0.01 unit is visually irrelevant.
    if (points.size() == 1) {
      points.emplace_back(points.front().X + 0.01f, points.front().Y + 0.01f);
    }
    total_points += raw_points->size();
    strokes.emplace_back(std::move(points));
  }
  if (strokes.empty() || total_points == 0) {
    throw std::invalid_argument("ink is empty");
  }
  return strokes;
}

std::string AsciiLower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](char character) {
    const auto byte = static_cast<unsigned char>(character);
    return static_cast<char>(std::tolower(byte));
  });
  return value;
}

bool RecognizerMatchesLanguage(const InkRecognizer& recognizer,
                               const std::string& language_tag) {
  const auto name = AsciiLower(winrt::to_string(recognizer.Name()));
  const auto tag = AsciiLower(language_tag);
  if (name.find(tag) != std::string::npos) {
    return true;
  }
  if (tag.rfind("de", 0) == 0) {
    return name.find("german") != std::string::npos ||
           name.find("deutsch") != std::string::npos;
  }
  if (tag.rfind("en", 0) == 0) {
    return name.find("english") != std::string::npos;
  }
  return false;
}

InkRecognizerContainer CreateRecognizer(const std::string& language_tag) {
  InkRecognizerContainer recognizer;
  const auto installed = recognizer.GetRecognizers();
  if (installed.Size() == 0) {
    throw std::runtime_error("no Windows Ink recognizer is installed");
  }
  for (const auto& candidate : installed) {
    if (RecognizerMatchesLanguage(candidate, language_tag)) {
      recognizer.SetDefaultRecognizer(candidate);
      break;
    }
  }
  return recognizer;
}

winrt::Windows::Media::Ocr::OcrEngine CreateOcrEngine(
    const std::string& language_tag) {
  using winrt::Windows::Globalization::Language;
  using winrt::Windows::Media::Ocr::OcrEngine;
  try {
    const Language requested(winrt::to_hstring(language_tag));
    if (OcrEngine::IsLanguageSupported(requested)) {
      auto engine = OcrEngine::TryCreateFromLanguage(requested);
      if (engine) {
        return engine;
      }
    }
  } catch (const winrt::hresult_error&) {
    // A malformed or unavailable language falls through to the user profile.
  }
  try {
    if (auto engine = OcrEngine::TryCreateFromUserProfileLanguages()) {
      return engine;
    }
  } catch (const winrt::hresult_error&) {
    // Continue with explicit locally installed fallback languages.
  }
  // Corporate Windows images sometimes have an OCR language installed that
  // is absent from the user language list. Prefer German, then English.
  for (const auto* fallback_tag : {L"de-DE", L"en-US"}) {
    try {
      const Language fallback(fallback_tag);
      if (OcrEngine::IsLanguageSupported(fallback)) {
        if (auto engine = OcrEngine::TryCreateFromLanguage(fallback)) {
          return engine;
        }
      }
    } catch (const winrt::hresult_error&) {
      // Continue with the next locally installed language.
    }
  }
  return nullptr;
}

struct InkRecognitionAttempt {
  bool available = false;
  std::optional<std::string> text;
};

std::string TrimAsciiWhitespace(std::string value) {
  const auto is_space = [](unsigned char character) {
    return std::isspace(character) != 0;
  };
  value.erase(value.begin(),
              std::find_if(value.begin(), value.end(),
                           [&](char character) {
                             return !is_space(
                                 static_cast<unsigned char>(character));
                           }));
  value.erase(std::find_if(value.rbegin(), value.rend(),
                           [&](char character) {
                             return !is_space(
                                 static_cast<unsigned char>(character));
                           })
                  .base(),
              value.end());
  return value;
}

InkRecognitionAttempt TryRecognizeWithWindowsInk(
    const std::string& language_tag,
    const std::vector<std::vector<InkPoint>>& strokes) {
  try {
    auto recognizer = CreateRecognizer(language_tag);
    InkStrokeContainer stroke_container;
    InkStrokeBuilder stroke_builder;
    for (const auto& points : strokes) {
      auto copied_points = points;
      auto point_vector =
          winrt::single_threaded_vector<InkPoint>(std::move(copied_points));
      stroke_container.AddStroke(stroke_builder.CreateStroke(point_vector));
    }
    const auto words = recognizer
                           .RecognizeAsync(stroke_container,
                                           InkRecognitionTarget::All)
                           .get();
    std::string text;
    for (const auto& word : words) {
      const auto candidates = word.GetTextCandidates();
      if (candidates.Size() == 0) {
        continue;
      }
      auto candidate = TrimAsciiWhitespace(
          winrt::to_string(candidates.GetAt(0)));
      if (candidate.empty()) {
        continue;
      }
      if (!text.empty()) {
        text.push_back(' ');
      }
      text += candidate;
    }
    return InkRecognitionAttempt{
        true, text.empty() ? std::nullopt
                           : std::optional<std::string>(std::move(text))};
  } catch (const winrt::hresult_error&) {
    return {};
  } catch (const std::exception&) {
    return {};
  }
}

void MarkLine(std::vector<uint8_t>& mask,
              uint32_t width,
              uint32_t height,
              float x0,
              float y0,
              float x1,
              float y1,
              size_t& raster_steps) {
  const float delta_x = x1 - x0;
  const float delta_y = y1 - y0;
  const auto steps = static_cast<size_t>(
      std::ceil(std::max(std::abs(delta_x), std::abs(delta_y))));
  if (steps > kMaximumRasterSteps - raster_steps) {
    throw std::length_error("ink exceeds the safe raster operation budget");
  }
  raster_steps += std::max<size_t>(steps, 1);
  const auto mark = [&](float x, float y) {
    const auto pixel_x = static_cast<int>(std::lround(x));
    const auto pixel_y = static_cast<int>(std::lround(y));
    if (pixel_x >= 0 && pixel_y >= 0 &&
        pixel_x < static_cast<int>(width) &&
        pixel_y < static_cast<int>(height)) {
      mask[static_cast<size_t>(pixel_y) * width + pixel_x] = 0;
    }
  };
  if (steps == 0) {
    mark(x0, y0);
    return;
  }
  for (size_t step = 0; step <= steps; ++step) {
    const float progress = static_cast<float>(step) /
                           static_cast<float>(steps);
    mark(x0 + delta_x * progress, y0 + delta_y * progress);
  }
}

std::vector<uint8_t> DilateInk(const std::vector<uint8_t>& source,
                               uint32_t width,
                               uint32_t height) {
  std::vector<uint8_t> horizontal(source.size(), 255);
  std::vector<uint8_t> result(source.size(), 255);
  for (uint32_t y = 0; y < height; ++y) {
    int black_count = 0;
    for (int x = 0; x <= kStrokeRadius &&
                    x < static_cast<int>(width);
         ++x) {
      black_count += source[static_cast<size_t>(y) * width + x] == 0;
    }
    for (uint32_t x = 0; x < width; ++x) {
      horizontal[static_cast<size_t>(y) * width + x] =
          black_count > 0 ? 0 : 255;
      const int remove_x = static_cast<int>(x) - kStrokeRadius;
      const int add_x = static_cast<int>(x) + kStrokeRadius + 1;
      if (remove_x >= 0) {
        black_count -=
            source[static_cast<size_t>(y) * width + remove_x] == 0;
      }
      if (add_x < static_cast<int>(width)) {
        black_count +=
            source[static_cast<size_t>(y) * width + add_x] == 0;
      }
    }
  }
  for (uint32_t x = 0; x < width; ++x) {
    int black_count = 0;
    for (int y = 0; y <= kStrokeRadius &&
                    y < static_cast<int>(height);
         ++y) {
      black_count += horizontal[static_cast<size_t>(y) * width + x] == 0;
    }
    for (uint32_t y = 0; y < height; ++y) {
      result[static_cast<size_t>(y) * width + x] =
          black_count > 0 ? 0 : 255;
      const int remove_y = static_cast<int>(y) - kStrokeRadius;
      const int add_y = static_cast<int>(y) + kStrokeRadius + 1;
      if (remove_y >= 0) {
        black_count -=
            horizontal[static_cast<size_t>(remove_y) * width + x] == 0;
      }
      if (add_y < static_cast<int>(height)) {
        black_count +=
            horizontal[static_cast<size_t>(add_y) * width + x] == 0;
      }
    }
  }
  return result;
}

winrt::Windows::Graphics::Imaging::SoftwareBitmap RasterizeInkForOcr(
    const std::vector<std::vector<InkPoint>>& strokes) {
  using namespace winrt::Windows::Graphics::Imaging;
  float left = std::numeric_limits<float>::infinity();
  float top = std::numeric_limits<float>::infinity();
  float right = -std::numeric_limits<float>::infinity();
  float bottom = -std::numeric_limits<float>::infinity();
  for (const auto& stroke : strokes) {
    for (const auto& point : stroke) {
      left = std::min(left, point.X);
      top = std::min(top, point.Y);
      right = std::max(right, point.X);
      bottom = std::max(bottom, point.Y);
    }
  }
  const float ink_width = std::max(right - left, 1.0f);
  const float ink_height = std::max(bottom - top, 1.0f);
  const auto ocr_limit = static_cast<uint32_t>(
      winrt::Windows::Media::Ocr::OcrEngine::MaxImageDimension());
  const uint32_t max_dimension =
      std::min(kMaximumBitmapDimension, ocr_limit);
  if (max_dimension < kMinimumBitmapDimension) {
    throw std::runtime_error("Windows OCR image limit is too small");
  }
  const float maximum_content_width =
      static_cast<float>(max_dimension) - kBitmapPadding * 2.0f;
  const float maximum_content_height =
      static_cast<float>(std::min(kMaximumOcrHeight, max_dimension)) -
      kBitmapPadding * 2.0f;
  float scale = kTargetInkHeight / ink_height;
  scale = std::min(scale, maximum_content_width / ink_width);
  scale = std::min(scale, maximum_content_height / ink_height);
  scale = std::clamp(scale, 0.05f, 64.0f);

  const uint32_t width = std::clamp(
      static_cast<uint32_t>(std::ceil(ink_width * scale +
                                      kBitmapPadding * 2.0f)),
      kMinimumBitmapDimension, max_dimension);
  const uint32_t height = std::clamp(
      static_cast<uint32_t>(std::ceil(ink_height * scale +
                                      kBitmapPadding * 2.0f)),
      kMinimumBitmapDimension,
      std::min(kMaximumOcrHeight, max_dimension));
  std::vector<uint8_t> center_lines(static_cast<size_t>(width) * height, 255);
  size_t raster_steps = 0;
  for (const auto& stroke : strokes) {
    for (size_t index = 1; index < stroke.size(); ++index) {
      const auto& previous = stroke[index - 1];
      const auto& current = stroke[index];
      MarkLine(center_lines, width, height,
               (previous.X - left) * scale + kBitmapPadding,
               (previous.Y - top) * scale + kBitmapPadding,
               (current.X - left) * scale + kBitmapPadding,
               (current.Y - top) * scale + kBitmapPadding, raster_steps);
    }
  }
  const auto mask = DilateInk(center_lines, width, height);
  SoftwareBitmap bitmap(BitmapPixelFormat::Bgra8, width, height,
                        BitmapAlphaMode::Premultiplied);
  auto buffer = bitmap.LockBuffer(BitmapBufferAccessMode::Write);
  const auto plane = buffer.GetPlaneDescription(0);
  if (plane.Stride <= 0) {
    throw std::runtime_error("Windows OCR bitmap has an invalid stride");
  }
  auto reference = buffer.CreateReference();
  auto byte_access = reference.as<IMemoryBufferByteAccess>();
  uint8_t* pixels = nullptr;
  uint32_t capacity = 0;
  winrt::check_hresult(byte_access->GetBuffer(&pixels, &capacity));
  const uint64_t required = static_cast<uint64_t>(plane.StartIndex) +
                            static_cast<uint64_t>(plane.Stride) * (height - 1) +
                            static_cast<uint64_t>(width) * 4;
  if (pixels == nullptr || required > capacity) {
    throw std::runtime_error("Windows OCR bitmap buffer is too small");
  }
  for (uint32_t y = 0; y < height; ++y) {
    auto* row = pixels + plane.StartIndex +
                static_cast<size_t>(plane.Stride) * y;
    for (uint32_t x = 0; x < width; ++x) {
      const uint8_t luminance = mask[static_cast<size_t>(y) * width + x];
      row[x * 4] = luminance;
      row[x * 4 + 1] = luminance;
      row[x * 4 + 2] = luminance;
      row[x * 4 + 3] = 255;
    }
  }
  return bitmap;
}

std::optional<std::string> TryRecognizeWithWindowsOcr(
    const winrt::Windows::Media::Ocr::OcrEngine& engine,
    const std::vector<std::vector<InkPoint>>& strokes) {
  try {
    auto bitmap = RasterizeInkForOcr(strokes);
    const auto result = engine.RecognizeAsync(bitmap).get();
    auto text = TrimAsciiWhitespace(winrt::to_string(result.Text()));
    return text.empty() ? std::nullopt
                        : std::optional<std::string>(std::move(text));
  } catch (const winrt::hresult_error&) {
    return std::nullopt;
  }
}

NativeResponse TextResponse(std::string text, const char* engine) {
  EncodableMap response;
  response.emplace(EncodableValue("text"), EncodableValue(std::move(text)));
  response.emplace(EncodableValue("engine"), EncodableValue(engine));
  return NativeResponse{true, EncodableValue(response), {}, {}};
}

NativeResponse CheckAvailability(const EncodableValue& arguments) {
  try {
    const auto language_tag = ReadLanguageTag(arguments);
    try {
      static_cast<void>(CreateRecognizer(language_tag));
      return NativeResponse{true, EncodableValue(true), {}, {}};
    } catch (const std::exception&) {
      // Continue with OCR; Handwriting=False does not disable Windows OCR.
    }
    return NativeResponse{true,
                          EncodableValue(static_cast<bool>(
                              CreateOcrEngine(language_tag))),
                          {},
                          {}};
  } catch (const winrt::hresult_error&) {
    return NativeResponse{true, EncodableValue(false), {}, {}};
  } catch (const std::exception&) {
    return NativeResponse{true, EncodableValue(false), {}, {}};
  }
}

NativeResponse Recognize(const EncodableValue& arguments) {
  try {
    const auto language_tag = ReadLanguageTag(arguments);
    const auto strokes = ReadStrokes(arguments);
    const auto ink_attempt =
        TryRecognizeWithWindowsInk(language_tag, strokes);
    if (ink_attempt.text) {
      return TextResponse(*ink_attempt.text, "windowsInk");
    }
    const auto ocr_engine = CreateOcrEngine(language_tag);
    if (ocr_engine) {
      if (const auto text = TryRecognizeWithWindowsOcr(ocr_engine, strokes)) {
        return TextResponse(*text, "windowsOcr");
      }
    }
    if (ink_attempt.available || ocr_engine) {
      return NativeResponse{false, EncodableValue(), "no_candidate",
                            "Die Handschrift wurde nicht erkannt."};
    }
    return NativeResponse{
        false, EncodableValue(), "recognizer_unavailable",
        "Windows stellt weder Ink- noch OCR-Erkennung lokal bereit."};
  } catch (const std::invalid_argument&) {
    return NativeResponse{false,
                          EncodableValue(),
                          "invalid_ink",
                          "Die Handschriftdaten sind ungültig."};
  } catch (const std::length_error&) {
    return NativeResponse{false,
                          EncodableValue(),
                          "invalid_ink",
                          "Die Auswahl ist für die lokale Erkennung zu groß."};
  } catch (const winrt::hresult_error& error) {
    return NativeResponse{
        false,
        EncodableValue(),
        "recognizer_unavailable",
        "Windows Ink konnte die Handschrift nicht lokal erkennen (0x" +
            std::to_string(static_cast<uint32_t>(error.code())) + ")."};
  } catch (const std::exception&) {
    return NativeResponse{
        false,
        EncodableValue(),
        "recognizer_unavailable",
        "In Windows ist kein lokaler Handschrifterkenner verfügbar."};
  }
}

void PostCompletion(
    const std::shared_ptr<WindowsHandwritingRecognitionService::SharedState>&
        state,
    std::unique_ptr<FlutterResult> result,
    NativeResponse response) {
  if (!state->active.load()) {
    return;
  }
  auto completion = std::make_unique<ChannelCompletion>(
      ChannelCompletion{state, std::move(result), std::move(response)});
  if (!::PostMessage(state->window, kRecognitionCompletedMessage, 0,
                     reinterpret_cast<LPARAM>(completion.get()))) {
    return;
  }
  completion.release();
}

}  // namespace

WindowsHandwritingRecognitionService::WindowsHandwritingRecognitionService(
    flutter::BinaryMessenger* messenger,
    HWND window)
    : state_(std::make_shared<SharedState>(window)),
      channel_(std::make_unique<
               flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kChannelName,
          &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

WindowsHandwritingRecognitionService::~WindowsHandwritingRecognitionService() {
  Dispose();
}

void WindowsHandwritingRecognitionService::Dispose() {
  if (!state_ || !state_->active.exchange(false)) {
    return;
  }
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }
}

void WindowsHandwritingRecognitionService::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const bool availability_call = call.method_name() == "ensureModel" ||
                                 call.method_name() == "isAvailable";
  if (!availability_call && call.method_name() != "recognize") {
    result->NotImplemented();
    return;
  }
  const auto arguments = call.arguments() == nullptr
                             ? flutter::EncodableValue()
                             : *call.arguments();
  const auto state = state_;
  try {
    std::thread([state, arguments, availability_call,
                 result = std::move(result)]() mutable {
      try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        auto response = availability_call ? CheckAvailability(arguments)
                                          : Recognize(arguments);
        PostCompletion(state, std::move(result), std::move(response));
      } catch (const std::exception&) {
        PostCompletion(
            state, std::move(result),
            NativeResponse{false,
                           flutter::EncodableValue(),
                           "recognizer_unavailable",
                           "Windows Ink konnte nicht gestartet werden."});
      }
    }).detach();
  } catch (const std::exception&) {
    if (result) {
      result->Error("recognizer_start_failed",
                    "Die lokale Handschrifterkennung konnte nicht gestartet "
                    "werden.");
    }
  }
}

bool WindowsHandwritingRecognitionService::HandleWindowMessage(UINT message,
                                                                LPARAM lparam) {
  if (message != kRecognitionCompletedMessage) {
    return false;
  }
  std::unique_ptr<ChannelCompletion> completion(
      reinterpret_cast<ChannelCompletion*>(lparam));
  if (!completion || !completion->state->active.load()) {
    return true;
  }
  if (completion->response.success) {
    completion->result->Success(completion->response.value);
  } else {
    completion->result->Error(completion->response.error_code,
                              completion->response.error_message);
  }
  return true;
}
