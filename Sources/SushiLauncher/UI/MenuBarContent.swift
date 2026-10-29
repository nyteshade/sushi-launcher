// Intentionally empty.
//
// This file held the SwiftUI MenuBarExtra dropdown content. The menu bar
// item is now an AppKit NSStatusItem owned by StatusItemController.swift
// (MenuBarExtra force-renders labels as alpha templates, which made the
// opaque artwork invisible, and its isInserted scene plumbing was a
// suspected launch-time recursion source).
