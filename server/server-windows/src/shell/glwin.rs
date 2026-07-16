//! Shared winit + glutin + egui_glow window bundle for every shell surface
//! (settings / main / pair / flyout). Extracted from the original 07-08
//! settings window so the Phase 10 redesign's four windows don't quadruple
//! the GL plumbing.
//!
//! Same discipline as before: egui-on-winit driven directly (NOT eframe —
//! RESEARCH Pitfall 4: eframe owns its own loop and cannot share the tray's),
//! glutin 0.32 + glutin-winit 0.5 exactly as egui_glow 0.35's `pure_glow`
//! example pairs them. Every fallible step surfaces as `anyhow::Error` so a
//! failed window is log-and-continue — never fatal to the tray.

use std::num::NonZeroU32;
use std::sync::Arc;

use egui_glow::glow;
use egui_glow::glow::HasContext as _;
use egui_glow::EguiGlow;
use glutin::config::ConfigTemplateBuilder;
use glutin::context::{ContextApi, ContextAttributesBuilder, PossiblyCurrentContext};
use glutin::display::GetGlDisplay as _;
use glutin::prelude::*;
use glutin::surface::{Surface, SurfaceAttributesBuilder, SwapInterval, WindowSurface};
use winit::dpi::PhysicalSize;
use winit::event::WindowEvent;
use winit::event_loop::{ActiveEventLoop, EventLoopProxy};
use winit::raw_window_handle::HasWindowHandle as _;
use winit::window::{Window, WindowAttributes, WindowId};

use super::style;
use super::UserEvent;

/// A winit `Window` + glutin GL context/surface + [`EguiGlow`], owned
/// together so a close drops the whole stack at once. Fonts + theme are
/// installed at build time; the repaint callback rides the shell loop's
/// `UserEvent::Repaint` queue.
pub struct GlWindow {
    window: Window,
    gl_context: PossiblyCurrentContext,
    gl_surface: Surface<WindowSurface>,
    gl: Arc<glow::Context>,
    egui_glow: EguiGlow,
}

impl GlWindow {
    /// Build the window + GL stack ON the shell loop (must be called from
    /// the shell thread with its `ActiveEventLoop`). The window is created
    /// hidden; call [`GlWindow::show`] after the first layout-affecting
    /// setup (position, size) is done.
    pub fn new(
        event_loop: &ActiveEventLoop,
        attrs: WindowAttributes,
        proxy: EventLoopProxy<UserEvent>,
    ) -> anyhow::Result<Self> {
        let attrs = attrs.with_visible(false);

        // A bare RGBA config — no depth/stencil needed for a 2D UI.
        let template = ConfigTemplateBuilder::new()
            .prefer_hardware_accelerated(None)
            .with_depth_size(0)
            .with_stencil_size(0)
            .with_transparency(false);

        // WR-05: the config-picker closure MUST return a `Config`, so an empty
        // iterator (broken/remote GPU stack — RDP, stale drivers, VMs) can only
        // be signalled by panicking. Contain the unwind so a dead GPU never
        // takes the tray down.
        let build_result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            glutin_winit::DisplayBuilder::new()
                .with_preference(glutin_winit::ApiPreference::FallbackEgl)
                .with_window_attributes(Some(attrs.clone()))
                .build(event_loop, template, |mut configs| {
                    configs.next().expect("no OpenGL config available")
                })
        }));
        let (window, gl_config) = match build_result {
            Ok(Ok(pair)) => pair,
            Ok(Err(e)) => return Err(anyhow::anyhow!("GL display/config creation failed: {e}")),
            Err(_) => return Err(anyhow::anyhow!("no OpenGL config available")),
        };

        // DisplayBuilder MAY create the window while probing configs; if it
        // didn't, finalize it against the chosen config now.
        let window = match window {
            Some(w) => w,
            None => glutin_winit::finalize_window(event_loop, attrs, &gl_config)
                .map_err(|e| anyhow::anyhow!("window creation failed: {e}"))?,
        };

        let raw_handle = window
            .window_handle()
            .map_err(|e| anyhow::anyhow!("window handle unavailable: {e}"))?
            .as_raw();
        let gl_display = gl_config.display();

        // Core GL first; GLES fallback second (egui_glow example discipline).
        let context_attrs = ContextAttributesBuilder::new().build(Some(raw_handle));
        let fallback_attrs = ContextAttributesBuilder::new()
            .with_context_api(ContextApi::Gles(None))
            .build(Some(raw_handle));
        // SAFETY: raw_handle belongs to `window`, which this struct owns for
        // at least as long as the context/surface built from it.
        let not_current = unsafe {
            gl_display
                .create_context(&gl_config, &context_attrs)
                .or_else(|_| gl_display.create_context(&gl_config, &fallback_attrs))
        }
        .map_err(|e| anyhow::anyhow!("GL context creation failed: {e}"))?;

        let (width, height): (u32, u32) = window.inner_size().into();
        let surface_attrs = SurfaceAttributesBuilder::<WindowSurface>::new().build(
            raw_handle,
            NonZeroU32::new(width).unwrap_or(NonZeroU32::MIN),
            NonZeroU32::new(height).unwrap_or(NonZeroU32::MIN),
        );
        // SAFETY: same raw_handle ownership argument as create_context above.
        let gl_surface = unsafe { gl_display.create_window_surface(&gl_config, &surface_attrs) }
            .map_err(|e| anyhow::anyhow!("GL surface creation failed: {e}"))?;
        let gl_context = not_current
            .make_current(&gl_surface)
            .map_err(|e| anyhow::anyhow!("make_current failed: {e}"))?;
        // Block swap on vsync so a repaint-happy frame can never spin the
        // shell thread (best-effort — some drivers refuse; that's fine).
        let _ = gl_surface.set_swap_interval(&gl_context, SwapInterval::Wait(NonZeroU32::MIN));

        // SAFETY: the display outlives `gl` (both owned by this struct); the
        // loader closure only resolves symbol addresses.
        let gl = Arc::new(unsafe {
            glow::Context::from_loader_function(|symbol| {
                let c = std::ffi::CString::new(symbol)
                    .expect("GL symbol names never contain interior NULs");
                gl_display.get_proc_address(&c)
            })
        });

        let egui_glow = EguiGlow::new(event_loop, Arc::clone(&gl), None, None, true);
        // Phase 10 design language: vendored fonts + dark shell visuals.
        style::install_fonts(&egui_glow.egui_ctx);
        style::apply_theme(&egui_glow.egui_ctx);
        // Delayed repaints (cursor blink, countdowns) ride the shell loop's
        // user-event queue — `Repaint` sets Wait/WaitUntil there.
        let repaint_proxy = egui::mutex::Mutex::new(proxy);
        egui_glow.egui_ctx.set_request_repaint_callback(move |info| {
            let _ = repaint_proxy
                .lock()
                .send_event(UserEvent::Repaint(info.delay));
        });

        Ok(Self {
            window,
            gl_context,
            gl_surface,
            gl,
            egui_glow,
        })
    }

    /// The underlying winit window (positioning, focus, dragging).
    pub fn window(&self) -> &Window {
        &self.window
    }

    /// The winit id — the shell loop routes `WindowEvent`s by it.
    pub fn window_id(&self) -> WindowId {
        self.window.id()
    }

    /// Reveal the (hidden-at-build) window.
    pub fn show(&self) {
        self.window.set_visible(true);
    }

    /// Bring an already-open window to the front.
    pub fn focus(&self) {
        self.window.focus_window();
    }

    /// Ask the OS for a redraw (egui repaint scheduling).
    pub fn request_redraw(&self) {
        self.window.request_redraw();
    }

    /// Resize the GL surface with the window (a zero dimension — minimize —
    /// is skipped; GL surfaces reject it).
    pub fn resize(&self, size: PhysicalSize<u32>) {
        if size.width == 0 || size.height == 0 {
            return;
        }
        self.gl_surface.resize(
            &self.gl_context,
            NonZeroU32::new(size.width).unwrap_or(NonZeroU32::MIN),
            NonZeroU32::new(size.height).unwrap_or(NonZeroU32::MIN),
        );
    }

    /// Forward a window event to egui; returns whether egui wants a repaint.
    pub fn on_window_event(&mut self, event: &WindowEvent) -> bool {
        self.egui_glow.on_window_event(&self.window, event).repaint
    }

    /// Run one egui frame + paint + swap (the `RedrawRequested` handler).
    /// `clear` is the GL clear color behind egui's paint. The closure also
    /// receives the winit `Window` (custom-chrome dragging needs it).
    pub fn redraw(
        &mut self,
        clear: (f32, f32, f32),
        mut run_ui: impl FnMut(&Window, &mut egui::Ui),
    ) {
        let Self {
            window,
            gl_context,
            gl_surface,
            gl,
            egui_glow,
        } = self;
        let window: &Window = window;
        // Only one GL context can be current per thread: with several shell
        // windows open, another window's redraw/creation has stolen currency
        // since ours — re-bind or every draw lands on the wrong surface.
        if let Err(e) = gl_context.make_current(gl_surface) {
            tracing::warn!(error = %e, "shell window make_current failed; skipping frame");
            return;
        }
        egui_glow.run(window, |ui| run_ui(window, ui));
        // SAFETY: plain state-set + clear on our own current GL context.
        unsafe {
            gl.clear_color(clear.0, clear.1, clear.2, 1.0);
            gl.clear(glow::COLOR_BUFFER_BIT);
        }
        egui_glow.paint(window);
        if let Err(e) = gl_surface.swap_buffers(gl_context) {
            // Cosmetic failure — never panic the shell loop over a frame.
            tracing::warn!(error = %e, "shell window swap_buffers failed");
        }
    }

    /// Release GPU resources (called right before the window is dropped).
    pub fn destroy(&mut self) {
        // Re-bind OUR context first: destroy() issues GL deletes, and if a
        // sibling window's context is current those deletes hit ITS textures
        // (font atlas!) instead — the "other window goes blank" bug.
        if self.gl_context.make_current(&self.gl_surface).is_err() {
            return; // context already lost; nothing to free
        }
        self.egui_glow.destroy();
    }
}
