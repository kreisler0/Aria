using Aria.Core.ViewModels;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace AriaWindows.Views;

/// <summary>Backend setup and email/password sign-in (Supabase Auth).</summary>
public sealed partial class LoginPage : UserControl
{
    public AppViewModel ViewModel => App.ViewModel;

    public LoginPage()
    {
        InitializeComponent();
    }

    private void Password_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter) return;
        e.Handled = true;
        if (sender is PasswordBox box) ViewModel.PasswordInput = box.Password;
        if (ViewModel.SubmitAuthCommand.CanExecute(null)) ViewModel.SubmitAuthCommand.Execute(null);
    }
}
