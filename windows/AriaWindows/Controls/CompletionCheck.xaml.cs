using System.Numerics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;

namespace AriaWindows.Controls;

/// <summary>
/// Round completion toggle: the fill springs in (composition natural-motion spring, damping
/// 0.8 — the Windows counterpart of the iOS <c>.spring(response: 0.4, dampingFraction: 0.8)</c>)
/// and the checkmark draws on instead of snapping.
/// </summary>
public sealed partial class CompletionCheck : UserControl
{
    public static readonly DependencyProperty IsCheckedProperty = DependencyProperty.Register(
        nameof(IsChecked), typeof(bool), typeof(CompletionCheck),
        new PropertyMetadata(false, (d, e) => ((CompletionCheck)d).Apply((bool)e.NewValue)));

    private bool _animateNext;

    public CompletionCheck()
    {
        InitializeComponent();
        Apply(IsChecked);
    }

    public bool IsChecked
    {
        get => (bool)GetValue(IsCheckedProperty);
        set => SetValue(IsCheckedProperty, value);
    }

    private void ToggleButton_Click(object sender, RoutedEventArgs e)
    {
        _animateNext = true;
        IsChecked = !IsChecked;
    }

    private void Apply(bool isChecked)
    {
        var animate = _animateNext;
        _animateNext = false;

        var visual = ElementCompositionPreview.GetElementVisual(FillCircle);
        var compositor = visual.Compositor;
        visual.CenterPoint = new Vector3(12, 12, 0);
        var targetScale = isChecked ? Vector3.One : new Vector3(0.2f, 0.2f, 1);
        if (animate)
        {
            var spring = compositor.CreateSpringVector3Animation();
            spring.FinalValue = targetScale;
            spring.DampingRatio = 0.8f;
            spring.Period = TimeSpan.FromMilliseconds(55);
            visual.StartAnimation("Scale", spring);
            var fade = compositor.CreateScalarKeyFrameAnimation();
            fade.InsertKeyFrame(1f, isChecked ? 1f : 0f);
            fade.Duration = TimeSpan.FromMilliseconds(160);
            visual.StartAnimation("Opacity", fade);
        }
        else
        {
            visual.Scale = targetScale;
            visual.Opacity = isChecked ? 1f : 0f;
        }

        var draw = new DoubleAnimation
        {
            To = isChecked ? 0 : 10,
            Duration = animate ? TimeSpan.FromMilliseconds(isChecked ? 320 : 120) : TimeSpan.Zero,
            EnableDependentAnimation = true,
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
        };
        Storyboard.SetTarget(draw, CheckPath);
        Storyboard.SetTargetProperty(draw, "StrokeDashOffset");
        var storyboard = new Storyboard();
        storyboard.Children.Add(draw);
        storyboard.Begin();

        Ring.Stroke = isChecked
            ? Helpers.Ui.Resource("AccentFillColorDefaultBrush", Microsoft.UI.Colors.RoyalBlue)
            : Helpers.Ui.Resource("TextFillColorSecondaryBrush", Microsoft.UI.Colors.Gray);
        AutomationProperties.SetName(ToggleButton, isChecked ? "Completed" : "Not completed");
    }
}
