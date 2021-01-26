/*
* Copyright (c) 2020 elementary, Inc. (https://elementary.io)
*
* This program is free software; you can redistribute it and/or
* modify it under the terms of the GNU General Public
* License as published by the Free Software Foundation; either
* version 3 of the License, or (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
* General Public License for more details.
*
* You should have received a copy of the GNU General Public
* License along with this program; if not, write to the
* Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
* Boston, MA 02110-1301 USA
*
* Authored by: Marius Meisenzahl <mariusmeisenzahl@gmail.com>
*/

public class About.FirmwareView : Gtk.Stack {
    private Hdy.Deck deck;
    private Gtk.Grid grid;
    private Granite.Widgets.AlertView progress_alert_view;
    private Gtk.Grid progress_view;
    private Gtk.ListBox update_list;
    private FwupdManager fwupd;

    construct {
        fwupd = new FwupdManager ();

        transition_type = Gtk.StackTransitionType.SLIDE_LEFT_RIGHT;

        progress_alert_view = new Granite.Widgets.AlertView (
            "",
            _("Do not unplug the device during the update."),
            "emblem-synchronized"
        );
        progress_alert_view.get_style_context ().remove_class (Gtk.STYLE_CLASS_VIEW);

        progress_view = new Gtk.Grid () {
            margin = 24
        };
        progress_view.attach (progress_alert_view, 0, 0);

        var no_devices_alert_view = new Granite.Widgets.AlertView (
            _("No Updatable Devices"),
            _("Firmware updates are not supported on this or any connected devices."),
            "application-x-firmware"
        );
        no_devices_alert_view.show_all ();
        no_devices_alert_view.get_style_context ().remove_class (Gtk.STYLE_CLASS_VIEW);

        update_list = new Gtk.ListBox () {
            vexpand = true,
            selection_mode = Gtk.SelectionMode.SINGLE
        };
        update_list.set_placeholder (no_devices_alert_view);

        update_list.row_activated.connect (show_release);

        var update_scrolled = new Gtk.ScrolledWindow (null, null);
        update_scrolled.add (update_list);

        deck = new Hdy.Deck () {
            can_swipe_back = true
        };
        deck.add (update_scrolled);

        var frame = new Gtk.Frame (null);
        frame.add (deck);

        grid = new Gtk.Grid () {
            column_spacing = 12,
            row_spacing = 12,
            margin = 12
        };
        grid.add (frame);

        add (grid);
        add (progress_view);

        fwupd.on_device_added.connect (on_device_added);
        fwupd.on_device_error.connect (on_device_error);
        fwupd.on_device_removed.connect (on_device_removed);

        update_list_view.begin ();
    }

    private async void update_list_view () {
        foreach (unowned Gtk.Widget widget in update_list.get_children ()) {
            if (widget is Widgets.FirmwareUpdateRow) {
                update_list.remove (widget);
            }
        }

        foreach (var device in yield fwupd.get_devices ()) {
            add_device (device);
        }

        visible_child = grid;
        update_list.show_all ();
    }

    private void add_device (Fwupd.Device device) {
        if (device.has_flag (Fwupd.DeviceFlag.UPDATABLE) && device.releases.length () > 0) {
            var row = new Widgets.FirmwareUpdateRow (fwupd, device);
            update_list.add (row);

            row.update.connect ((device, release) => {
                on_update_start (device);

                update.begin (device, device.latest_release, (obj, res) => {
                    update.end (res);
                    on_update_end ();
                });
            });
        }
    }

    private void on_update_start (Fwupd.Device device) {
        progress_alert_view.title = _("“%s” is being updated").printf (device.name);
        visible_child = progress_view;
    }

    private void on_update_end () {
        visible_child = grid;
        update_list_view.begin ();
    }

    private void on_device_added (Fwupd.Device device) {
        debug ("Added device: %s", device.name);

        add_device (device);

        visible_child = grid;
        update_list.show_all ();
    }

    private void on_device_error (Fwupd.Device device, string error) {
        var message_dialog = new Granite.MessageDialog.with_image_from_icon_name (
            _("Failed to install firmware release"),
            error,
            device.icon,
            Gtk.ButtonsType.CLOSE
        );
        message_dialog.transient_for = (Gtk.Window) get_toplevel ();
        message_dialog.badge_icon = new ThemedIcon ("dialog-error");
        message_dialog.show_all ();
        message_dialog.run ();
        message_dialog.destroy ();
    }

    private void on_device_removed (Fwupd.Device device) {
        debug ("Removed device: %s", device.name);

        foreach (unowned Gtk.Widget widget in update_list.get_children ()) {
            if (widget is Widgets.FirmwareUpdateRow) {
                var row = (Widgets.FirmwareUpdateRow) widget;
                if (row.device.id == device.id) {
                    update_list.remove (widget);
                }
            }
        }

        update_list.show_all ();
    }

    private void show_release (Gtk.ListBoxRow widget) {
        if (widget is Widgets.FirmwareUpdateRow) {
            var row = (Widgets.FirmwareUpdateRow) widget;
            var firmware_release_view = new FirmwareReleaseView (row.device, row.device.latest_release);
            deck.add (firmware_release_view);
            deck.visible_child = firmware_release_view;

            firmware_release_view.back.connect (() => {
                deck.navigate (Hdy.NavigationDirection.BACK);
                firmware_release_view.destroy ();
            });

            deck.child_switched.connect (() => {
                firmware_release_view.destroy ();
            });

            firmware_release_view.update.connect ((device, release) => {
                on_update_start (device);

                update.begin (device, release, (obj, res) => {
                    update.end (res);
                    on_update_end ();
                });
            });
        }
    }

    private async void update (Fwupd.Device device, Fwupd.Release release) {
        var path = yield fwupd.download_file (device, release.uri);

        var details = yield fwupd.get_release_details (device, path);

        if (details.caption != null) {
            if (show_details_dialog (device, details) == false) {
                return;
            }
        }

        if ((yield fwupd.install (device, path)) == true) {
            if (device.has_flag (Fwupd.DeviceFlag.NEEDS_REBOOT)) {
                show_reboot_dialog ();
            } else if (device.has_flag (Fwupd.DeviceFlag.NEEDS_SHUTDOWN)) {
                show_shutdown_dialog ();
            }
        }
    }

    private bool show_details_dialog (Fwupd.Device device, Fwupd.Details details) {
        var message_dialog = new Granite.MessageDialog.with_image_from_icon_name (
            _("“%s” needs to manually be put in update mode").printf (device.name),
            details.caption,
            device.icon,
            Gtk.ButtonsType.CANCEL
        );
        message_dialog.transient_for = (Gtk.Window) get_toplevel ();

        var suggested_button = new Gtk.Button.with_label (_("Continue"));
        suggested_button.get_style_context ().add_class (Gtk.STYLE_CLASS_SUGGESTED_ACTION);
        message_dialog.add_action_widget (suggested_button, Gtk.ResponseType.ACCEPT);

        if (details.image != null) {
            var custom_widget = new Gtk.Image.from_file (details.image);
            message_dialog.custom_bin.add (custom_widget);
        }

        message_dialog.badge_icon = new ThemedIcon ("dialog-information");
        message_dialog.show_all ();
        bool should_continue = message_dialog.run () == Gtk.ResponseType.ACCEPT;

        message_dialog.destroy ();

        return should_continue;
    }

    private void show_reboot_dialog () {
        var message_dialog = new Granite.MessageDialog.with_image_from_icon_name (
            _("An update requires the system to restart to complete"),
            _("This will close all open applications and restart this device."),
            "application-x-firmware",
            Gtk.ButtonsType.CANCEL
        );
        message_dialog.transient_for = (Gtk.Window) get_toplevel ();

        var suggested_button = new Gtk.Button.with_label (_("Restart"));
        suggested_button.get_style_context ().add_class (Gtk.STYLE_CLASS_DESTRUCTIVE_ACTION);
        message_dialog.add_action_widget (suggested_button, Gtk.ResponseType.ACCEPT);

        message_dialog.badge_icon = new ThemedIcon ("system-reboot");
        message_dialog.show_all ();
        if (message_dialog.run () == Gtk.ResponseType.ACCEPT) {
            LoginManager.get_instance ().reboot ();
        }

        message_dialog.destroy ();
    }

    private void show_shutdown_dialog () {
        var message_dialog = new Granite.MessageDialog.with_image_from_icon_name (
            _("An update requires the system to shut down to complete"),
            _("This will close all open applications and turn off this device."),
            "application-x-firmware",
            Gtk.ButtonsType.CANCEL
        );
        message_dialog.transient_for = (Gtk.Window) get_toplevel ();

        var suggested_button = new Gtk.Button.with_label (_("Shut Down"));
        suggested_button.get_style_context ().add_class (Gtk.STYLE_CLASS_DESTRUCTIVE_ACTION);
        message_dialog.add_action_widget (suggested_button, Gtk.ResponseType.ACCEPT);

        message_dialog.badge_icon = new ThemedIcon ("system-shutdown");
        message_dialog.show_all ();
        if (message_dialog.run () == Gtk.ResponseType.ACCEPT) {
            LoginManager.get_instance ().shutdown ();
        }

        message_dialog.destroy ();
    }
}
