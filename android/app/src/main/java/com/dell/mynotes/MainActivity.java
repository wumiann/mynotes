package com.dell.mynotes;

import android.annotation.SuppressLint;
import android.net.http.SslError;
import android.webkit.SslErrorHandler;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
  @SuppressLint("SetJavaScriptEnabled")
  @Override
  public void onCreate(android.os.Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
    // 局域网自签名证书（HTTPS 8443）：放行以支持浏览器加密能力所需的 HTTPS
    bridge
      .getWebView()
      .setWebViewClient(
        new WebViewClient() {
          @Override
          public void onReceivedSslError(WebView view, SslErrorHandler handler, SslError error) {
            handler.proceed();
          }
        }
      );
  }
}
