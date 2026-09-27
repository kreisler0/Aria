using System.Collections.Specialized;
using Aria.Core.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace AriaWindows.Views;

public sealed partial class AIChatPage : Page
{
    public AppViewModel ViewModel => App.ViewModel;

    public AIChatPage()
    {
        InitializeComponent();
        ViewModel.Chat.CollectionChanged += Chat_CollectionChanged;
        Unloaded += (_, _) => ViewModel.Chat.CollectionChanged -= Chat_CollectionChanged;
        Loaded += (_, _) =>
        {
            ScrollToEnd();
            Input.Focus(FocusState.Programmatic);
        };
    }

    private void Chat_CollectionChanged(object? sender, NotifyCollectionChangedEventArgs e) => ScrollToEnd();

    private void ScrollToEnd()
    {
        if (ViewModel.Chat.Count > 0) Messages.ScrollIntoView(ViewModel.Chat[^1]);
    }

    private void Input_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        // Enter sends; Shift+Enter would need AcceptsReturn, which the single-line box doesn't use.
        if (e.Key != VirtualKey.Enter) return;
        e.Handled = true;
        if (ViewModel.SendChatCommand.CanExecute(null)) ViewModel.SendChatCommand.Execute(null);
    }
}

/// <summary>Picks the bubble template for a chat message.</summary>
public sealed partial class BubbleTemplateSelector : DataTemplateSelector
{
    public DataTemplate? User { get; set; }
    public DataTemplate? Assistant { get; set; }
    public DataTemplate? Action { get; set; }
    public DataTemplate? Error { get; set; }

    protected override DataTemplate? SelectTemplateCore(object item) => item is ChatBubbleViewModel bubble
        ? bubble.Role switch
        {
            BubbleRole.User => User,
            BubbleRole.Action => Action,
            BubbleRole.Error => Error,
            _ => Assistant,
        }
        : Assistant;

    protected override DataTemplate? SelectTemplateCore(object item, DependencyObject container) => SelectTemplateCore(item);
}
