//
// PostScript Printer Application based on PAPPL and libpappl-retrofit
//
// Copyright © 2020 by Till Kamppeter.
// Copyright © 2020 by Michael R Sweet.
//
// Licensed under Apache License v2.0.  See the file "LICENSE" for more
// information.
//

//
// Include necessary headers...
//

#include <pappl-retrofit.h>


//
// Constants...
//

// Name and version

#define SYSTEM_NAME "PostScript Printer Application"
#define SYSTEM_PACKAGE_NAME "ps-printer-app"
#ifndef SYSTEM_VERSION_STR
#  define SYSTEM_VERSION_STR "1.0"
#endif
#ifndef SYSTEM_VERSION_ARR_0
#  define SYSTEM_VERSION_ARR_0 1
#endif
#ifndef SYSTEM_VERSION_ARR_1
#  define SYSTEM_VERSION_ARR_1 0
#endif
#ifndef SYSTEM_VERSION_ARR_2
#  define SYSTEM_VERSION_ARR_2 0
#endif
#ifndef SYSTEM_VERSION_ARR_3
#  define SYSTEM_VERSION_ARR_3 0
#endif
#define SYSTEM_WEB_IF_FOOTER "Copyright &copy; 2020 by Till Kamppeter. Provided under the terms of the <a href=\"https://www.apache.org/licenses/LICENSE-2.0\">Apache License 2.0</a>."

// Test page

#define TESTPAGE "testpage.pdf"


//
// 'ps_autoadd()' - Auto-add PostScript printers.
//

const char *			// O - Driver name or `NULL` for none
ps_autoadd(const char *device_info,	// I - Device name (unused)
	   const char *device_uri,	// I - Device URI (unused)
	   const char *device_id,	// I - IEEE-1284 device ID
	   void       *data)            // I - Global data
{
  pr_printer_app_global_data_t *global_data =
    (pr_printer_app_global_data_t *)data;
  const char	*ret = NULL;		// Return value


  (void)device_info;
  (void)device_uri;

  if (device_id == NULL || global_data == NULL)
    return (NULL);

  // Look at the COMMAND SET (CMD) key for the list of printer languages...
  //
  // There are several printers for which PostScript is available in an
  // add-on module, so there are printers with the same model name but
  // with and without PostScript support. So we auto-add printers only
  // if their device ID explicitly tells that they do PostScript
  // We only make an exception on device IDs which do not inform about
  // the printer's PDLs at all (no "CMD:" or "COMMAND SET:" fields)
  // allowing them always. This is because some backends do not
  // obtain the device ID from the printer but obtain make and model
  // by another method and make an artificial device ID from them.
  if ((strncmp(device_id, "CMD:", 4) &&
       strncmp(device_id, "COMMAND SET:", 12) &&
       strstr(device_id, ";CMD:") == NULL &&
       strstr(device_id, ";COMMAND SET:") == NULL) ||
      prSupportsPostScript(device_id))
  {
    // Printer supports PostScript, so find the best-matching PPD file.
    // prBestMatchingPPD() returns NULL when it finds neither a matching
    // driver nor a usable device ID, so the result must be checked before
    // it is compared - strcmp(NULL, ...) crashes the whole service.
    ret = prBestMatchingPPD(device_id, global_data);
    if (ret && strcmp(ret, "generic") == 0 && !prSupportsPostScript(device_id))
      ret = NULL;
  }
  else
    // Printer does not support PostScript, it is not supported by this
    // Printer Application
    ret = NULL;

  return (ret);
}


#ifndef PS_PRINTER_APP_NO_MAIN

//
// 'ps_printer_setup()' - Register per-printer web pages.
//

static void
ps_printer_setup(pappl_printer_t *printer,  // I - Printer
                 void            *data)     // I - Global data
{
  pappl_system_t *system = papplPrinterGetSystem(printer);
  char           path[256];                 // Device settings page path

  // Keep pappl-retrofit's setup: it publishes PPD human-readable strings
  // for IPP clients via printer-strings-uri.
  prSetupDeviceSettingsPage(printer, data);

  // If no-web-interface is set, remove Device Settings admin page
  if (!(papplSystemGetOptions(system) & PAPPL_SOPTIONS_WEB_INTERFACE))
  {
    papplPrinterGetPath(printer, "device", path, sizeof(path));
    papplSystemRemoveResource(system, path);
    papplPrinterRemoveLink(printer, "Device Settings");
  }
}


//
// 'ps_not_found_cb()' - Resource callback answering 404 Not Found.
//

static bool
ps_not_found_cb(pappl_client_t *client,     // I - Client
                void           *data)       // I - Unused
{
  (void)data;

  return (papplClientRespond(client, HTTP_STATUS_NOT_FOUND, NULL, NULL, 0, 0));
}


//
// 'ps_system_setup()' - Extra setup steps for the system.
//

static void
ps_system_setup(void *data)                 // I - Global data
{
  pr_printer_app_global_data_t *global_data = (pr_printer_app_global_data_t *)data;
  pappl_system_t               *system = prGetSystem(global_data);

  prSetupAddPPDFilesPage(data);

  // If no-web-interface is set, remove Add PPD Files admin page
  if (!(papplSystemGetOptions(system) & PAPPL_SOPTIONS_WEB_INTERFACE))
  {
    papplSystemRemoveResource(system, "/addppd");
    papplSystemRemoveLink(system, "Add PPD Files");

    // pappl-retrofit enables web-log by default and papplSystemRun() adds
    // /logs and /logfile.txt after this callback, regardless of the web
    // interface.  PAPPL keeps the first resource registered for a path, so
    // claiming both paths here with 404 handlers keeps the log unreachable.
    papplSystemAddResourceCallback(system, "/logs", "text/html", ps_not_found_cb, NULL);
    papplSystemAddResourceCallback(system, "/logfile.txt", "text/plain", ps_not_found_cb, NULL);
  }
}


//
// 'main()' - Main entry for the ps-printer-app.
//
// Skipped when building the unit tests, which link this file to exercise
// ps_autoadd() and supply their own main().
//

int
main(int  argc,				// I - Number of command-line arguments
     char *argv[])			// I - Command-line arguments
{
  cups_array_t *spooling_conversions,
               *stream_formats;
  int          ret;

  // Array of spooling conversions, most desirables first
  spooling_conversions = cupsArrayNew(NULL, NULL);
  cupsArrayAdd(spooling_conversions, (void *)&PR_CONVERT_PS_TO_PS);
  cupsArrayAdd(spooling_conversions, (void *)&PR_CONVERT_PDF_TO_PS);

  // Array of stream formats, most desirables first
  stream_formats = cupsArrayNew(NULL, NULL);
  cupsArrayAdd(stream_formats, (void *)&PR_STREAM_POSTSCRIPT);

  // Configuration record of the PostScript Printer Application
  pr_printer_app_config_t printer_app_config =
  {
    SYSTEM_NAME,
    SYSTEM_PACKAGE_NAME,
    SYSTEM_VERSION_STR,
    {
      SYSTEM_VERSION_ARR_0,
      SYSTEM_VERSION_ARR_1,
      SYSTEM_VERSION_ARR_2,
      SYSTEM_VERSION_ARR_3
    },
    SYSTEM_WEB_IF_FOOTER,
    PR_COPTIONS_QUERY_PS_DEFAULTS |
    PR_COPTIONS_WEB_ADD_PPDS |
    PR_COPTIONS_NO_PAPPL_BACKENDS |
    PR_COPTIONS_CUPS_BACKENDS,
    ps_autoadd,
    prIdentify,
    prTestPage,
    ps_system_setup,
    ps_printer_setup,
    spooling_conversions,
    stream_formats,
    "",
    "snmp,dnssd,usb",
    TESTPAGE,
    NULL,
    NULL
  };

  return (prRetroFitPrinterApp(&printer_app_config, argc, argv));
}

#endif // !PS_PRINTER_APP_NO_MAIN
