#ifndef RUNNER_WINDOWS_HANDWRITING_RECOGNITION_SERVICE_H_
#define RUNNER_WINDOWS_HANDWRITING_RECOGNITION_SERVICE_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <windows.h>

#include <atomic>
#include <memory>

namespace flutter {
class BinaryMessenger;
}

// Bridges Flowboard's vector ink to the recognizers built into Windows Ink.
// Recognition runs on a worker apartment; channel replies are marshalled back
// to Flutter's platform thread through a private window message.
class WindowsHandwritingRecognitionService {
 public:
  WindowsHandwritingRecognitionService(flutter::BinaryMessenger* messenger,
                                        HWND window);
  ~WindowsHandwritingRecognitionService();

  WindowsHandwritingRecognitionService(
      const WindowsHandwritingRecognitionService&) = delete;
  WindowsHandwritingRecognitionService& operator=(
      const WindowsHandwritingRecognitionService&) = delete;

  void Dispose();

  // Returns true when |message| was a recognition completion and consumed.
  static bool HandleWindowMessage(UINT message, LPARAM lparam);

  // Internal lifetime token shared with detached recognition workers. It is
  // public only so the translation unit can carry it in completion messages.
  struct SharedState {
    explicit SharedState(HWND target_window) : window(target_window) {}
    std::atomic<bool> active{true};
    HWND window;
  };

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::shared_ptr<SharedState> state_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_WINDOWS_HANDWRITING_RECOGNITION_SERVICE_H_
