using Aria.Core.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AriaWindows.Controls;

/// <summary>A task (with its completion check) or an event, as shown in every list.</summary>
public sealed partial class ItemRow : UserControl
{
    public static readonly DependencyProperty RowProperty = DependencyProperty.Register(
        nameof(Row), typeof(ItemRowViewModel), typeof(ItemRow), new PropertyMetadata(null));

    public ItemRow()
    {
        InitializeComponent();
    }

    public ItemRowViewModel Row
    {
        get => (ItemRowViewModel)GetValue(RowProperty);
        set => SetValue(RowProperty, value);
    }
}
