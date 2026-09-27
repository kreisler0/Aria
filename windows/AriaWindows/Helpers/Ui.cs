using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI.Text;

namespace AriaWindows.Helpers;

/// <summary>Small functions for x:Bind (visibility, strike-through, colours).</summary>
public static class Ui
{
    public static Visibility Visible(bool value) => value ? Visibility.Visible : Visibility.Collapsed;
    public static Visibility Collapsed(bool value) => value ? Visibility.Collapsed : Visibility.Visible;
    public static Visibility VisibleIfText(string? value) => string.IsNullOrWhiteSpace(value) ? Visibility.Collapsed : Visibility.Visible;
    public static bool Not(bool value) => !value;
    public static TextDecorations Strike(bool value) => value ? TextDecorations.Strikethrough : TextDecorations.None;
    public static double DoneOpacity(bool completed) => completed ? 0.55 : 1.0;

    public static Brush DetailBrush(bool overdue) => overdue
        ? new SolidColorBrush(Colors.IndianRed)
        : Resource("TextFillColorSecondaryBrush", Colors.Gray);

    /// <summary>A brush from the app's theme resources, with a fallback colour.</summary>
    public static Brush Resource(string key, Windows.UI.Color fallback) =>
        Application.Current.Resources.TryGetValue(key, out var value) && value is Brush brush ? brush : new SolidColorBrush(fallback);

    /// <summary>Sparkle outline used for "added by Aria" and the assistant.</summary>
    public const string Sparkle = "M8,0 L9.6,6.4 L16,8 L9.6,9.6 L8,16 L6.4,9.6 L0,8 L6.4,6.4 Z";
}
