#ifndef WEBVIEW_GTK
#error WEBVIEW_GTK must be defined. This is a implementation file!
#endif

//
// ====================================================================
//
// This implementation uses webkit2gtk backend. It requires gtk+3.0 and
// webkit2gtk-4.0 libraries. Proper compiler flags can be retrieved via:
//
//   pkg-config --cflags --libs gtk+-3.0 webkit2gtk-4.0
//
// ====================================================================
//
#include <JavaScriptCore/JavaScript.h>
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

class gtk_webkit_engine {
public:
  gtk_webkit_engine(bool debug, void *window)
      : m_window(static_cast<GtkWidget *>(window)) {
    gtk_init_check(0, NULL);
    m_window = static_cast<GtkWidget *>(window);
    if (m_window == nullptr) {
      m_window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    }
    g_signal_connect(G_OBJECT(m_window), "destroy",
                     G_CALLBACK(+[](GtkWidget *, gpointer arg) {
                       static_cast<gtk_webkit_engine *>(arg)->terminate();
                     }),
                     this);
    // Initialize webview widget
    m_webview = webkit_web_view_new();
    WebKitUserContentManager *manager =
        webkit_web_view_get_user_content_manager(WEBKIT_WEB_VIEW(m_webview));

    // link with target _blank click - open in system browser
    g_signal_connect(WEBKIT_WEB_VIEW(m_webview), "create", G_CALLBACK(external_window), this);
    
    g_signal_connect(manager, "script-message-received::external",
                     G_CALLBACK(+[](WebKitUserContentManager *,
                                    WebKitJavascriptResult *r, gpointer arg) {
                       auto *w = static_cast<gtk_webkit_engine *>(arg);
#if WEBKIT_MAJOR_VERSION >= 2 && WEBKIT_MINOR_VERSION >= 22
                       JSCValue *value =
                           webkit_javascript_result_get_js_value(r);
                       char *s = jsc_value_to_string(value);
#else
                       JSGlobalContextRef ctx = webkit_javascript_result_get_global_context(r);
                       JSValueRef value = webkit_javascript_result_get_value(r);
                       JSStringRef js = JSValueToStringCopy(ctx, value, NULL);
                       size_t n = JSStringGetMaximumUTF8CStringSize(js);
                       char *s = g_new(char, n);
                       JSStringGetUTF8CString(js, s, n);
                       JSStringRelease(js);
#endif
                       w->on_message(s);
                       g_free(s);
                     }),
                     this);
    webkit_user_content_manager_register_script_message_handler(manager,
                                                                "external");
    init("window.external={invoke:function(s){window.webkit.messageHandlers."
         "external.postMessage(s);}}");

    gtk_container_add(GTK_CONTAINER(m_window), GTK_WIDGET(m_webview));
    gtk_widget_grab_focus(GTK_WIDGET(m_webview));

    WebKitSettings *settings =
        webkit_web_view_get_settings(WEBKIT_WEB_VIEW(m_webview));
    webkit_settings_set_javascript_can_access_clipboard(settings, true);
    if (debug) {
      webkit_settings_set_enable_write_console_messages_to_stdout(settings,
                                                                  true);
      webkit_settings_set_enable_developer_extras(settings, true);
    }

    gtk_widget_show_all(m_window);
  }
  void *window() { return (void *)m_window; }
  void run() { gtk_main(); }
  void terminate() { gtk_main_quit(); }
  void dispatch(std::function<void()> f) {
    g_idle_add_full(G_PRIORITY_HIGH_IDLE, (GSourceFunc)([](void *f) -> int {
                      (*static_cast<dispatch_fn_t *>(f))();
                      return G_SOURCE_REMOVE;
                    }),
                    new std::function<void()>(f),
                    [](void *f) { delete static_cast<dispatch_fn_t *>(f); });
  }

  void set_title(const std::string title) {
    gtk_window_set_title(GTK_WINDOW(m_window), title.c_str());
  }

  void set_size(int width, int height, int hints) {
    gtk_window_set_resizable(GTK_WINDOW(m_window), hints != WEBVIEW_HINT_FIXED);
    if (hints == WEBVIEW_HINT_NONE) {
      gtk_window_resize(GTK_WINDOW(m_window), width, height);
    } else if (hints == WEBVIEW_HINT_FIXED) {
      gtk_widget_set_size_request(m_window, width, height);
    } else {
      GdkGeometry g;
      g.min_width = g.max_width = width;
      g.min_height = g.max_height = height;
      GdkWindowHints h =
          (hints == WEBVIEW_HINT_MIN ? GDK_HINT_MIN_SIZE : GDK_HINT_MAX_SIZE);
      // This defines either MIN_SIZE, or MAX_SIZE, but not both:
      gtk_window_set_geometry_hints(GTK_WINDOW(m_window), nullptr, &g, h);
    }
  }

  void set_icon(const std::string icon) {
    GtkIconTheme *icon_theme = gtk_icon_theme_get_default();
    gtk_icon_theme_append_search_path(icon_theme, g_path_get_dirname(icon.c_str())); 
    // get icon name as basename without extension
    size_t pos = icon.find_last_of(".");
    if (pos == std::string::npos) {
      pos = icon.length();
    }
    const gchar *basename = g_path_get_basename(icon.substr(0, pos).c_str());
    if (gtk_icon_theme_has_icon(icon_theme, basename)) {
        gtk_window_set_icon_name(GTK_WINDOW(m_window), basename);
        gtk_window_set_default_icon_name(basename);
    }
    else {
      GError* error = NULL;
      gtk_window_set_icon_from_file(GTK_WINDOW(m_window), icon.c_str(), &error);
      if (error != NULL) {
        fprintf(stderr, "Error setting icon: %s\n", error->message);
        g_error_free(error);
      }
      gtk_window_set_default_icon_from_file(icon.c_str(), &error);
      if (error != NULL) {
        fprintf(stderr, "Error setting default icon: %s\n", error->message);
        g_error_free(error);
      }
    }
  }

  static GtkWidget* external_window(WebKitWebView *wv, WebKitNavigationAction *a, gpointer arg) {
    WebKitNavigationAction *action = a;
    WebKitURIRequest *request = webkit_navigation_action_get_request(action);
    const gchar *uri = webkit_uri_request_get_uri(request);
    if (uri) {
      gtk_show_uri_on_window(NULL, uri, GDK_CURRENT_TIME, NULL);
    }
    return NULL;
  }

  void navigate(const std::string url) {
    webkit_web_view_load_uri(WEBKIT_WEB_VIEW(m_webview), url.c_str());
  }

  void init(const std::string js) {
    WebKitUserContentManager *manager =
        webkit_web_view_get_user_content_manager(WEBKIT_WEB_VIEW(m_webview));
    webkit_user_content_manager_add_script(
        manager, webkit_user_script_new(
                     js.c_str(), WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
                     WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, NULL, NULL));
  }

  void eval(const std::string js) {
    webkit_web_view_run_javascript(WEBKIT_WEB_VIEW(m_webview), js.c_str(), NULL,
                                   NULL, NULL);
  }

private:
  virtual void on_message(const std::string msg) = 0;
  GtkWidget *m_window;
  GtkWidget *m_webview;
};

using browser_engine = gtk_webkit_engine;
