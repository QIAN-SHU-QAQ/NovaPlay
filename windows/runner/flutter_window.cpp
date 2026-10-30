#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "desktop_multi_window/desktop_multi_window_plugin.h"
#include "flutter/generated_plugin_registrant.h"

namespace {

// Standalone player window is created by desktop_multi_window plugin.
// The plugin only exposes show/hide, so this file adds window decoration
// and a small method channel for close/setTitle.
constexpr wchar_t kPlayerWindowTitle[] = L"NovaPlay Player";

// Keep channels alive for the lifetime of the child engines.
std::vector<std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>>>
    g_player_window_channels;

std::wstring Utf8ToUtf16(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int length = MultiByteToWideChar(
      CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()),
                      result.data(), length);
  return result;
}

void CenterAndResizePlayerWindow(HWND root) {
  if (!root) {
    return;
  }
  ::SetWindowTextW(root, kPlayerWindowTitle);

  HMONITOR monitor = ::MonitorFromWindow(root, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO info{};
  info.cbSize = sizeof(MONITORINFO);
  const int width = 1280;
  const int height = 720;
  int x = 80;
  int y = 80;
  if (::GetMonitorInfoW(monitor, &info)) {
    const int work_width = info.rcWork.right - info.rcWork.left;
    const int work_height = info.rcWork.bottom - info.rcWork.top;
    x = info.rcWork.left + (work_width - width) / 2;
    y = info.rcWork.top + (work_height - height) / 2;
  }
  ::SetWindowPos(root, nullptr, x, y, width, height,
                 SWP_NOZORDER | SWP_SHOWWINDOW);
  ::SetForegroundWindow(root);
}

void AttachPlayerWindowChannel(flutter::FlutterViewController* controller) {
  if (!controller || !controller->engine() || !controller->view()) {
    return;
  }
  HWND root = ::GetAncestor(controller->view()->GetNativeWindow(), GA_ROOT);
  auto* engine = controller->engine();
  auto channel =
      std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
          engine->messenger(), "nova_play/player_window",
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [root](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "close") {
          if (root) {
            ::PostMessageW(root, WM_CLOSE, 0, 0);
          }
          result->Success();
        } else if (call.method_name() == "setTitle") {
          const auto* title = std::get_if<std::string>(call.arguments());
          if (root && title != nullptr) {
            ::SetWindowTextW(root, Utf8ToUtf16(*title).c_str());
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
  g_player_window_channels.push_back(channel);
}

void OnPlayerWindowCreated(void* flutter_view_controller) {
  auto* controller = reinterpret_cast<flutter::FlutterViewController*>(
      flutter_view_controller);
  if (!controller || !controller->engine() || !controller->view()) {
    return;
  }
  // Child windows have their own Flutter engine; register plugins manually.
  RegisterPlugins(controller->engine());
  HWND root = ::GetAncestor(controller->view()->GetNativeWindow(), GA_ROOT);
  CenterAndResizePlayerWindow(root);
  AttachPlayerWindowChannel(controller);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Called for every window created by desktop_multi_window.
  DesktopMultiWindowSetWindowCreatedCallback(OnPlayerWindowCreated);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
