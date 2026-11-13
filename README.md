# Des Moines Donatable Items Catalog

A small static website for browsing donatable inventory by category and location. It uses plain HTML, CSS, and JavaScript, so it does not need a build step or a server.

## Customize the catalog

1. Open `catalog.js`.
2. Update the entries in the `items` list with your inventory.
3. Give every item a unique `id` using lowercase letters, numbers, and hyphens.
4. Fill in the `name`, `category`, `location`, `ticketNumber`, and `quantity` for each item. Use `null` when the quantity is not known.
5. Add any item details to `description` and the item's image paths to `images`. Store website images in the `images` folder.
6. To add or rename categories or locations, edit the corresponding values in the item entries. The filter menus update automatically.

Example:

```js
{
  id: "dm2616125-01",
  name: "Blue Office Chair",
  category: "Chairs",
  location: "Customer Warehouse (T&M)",
  ticketNumber: "DM2616125-01",
  quantity: 1,
  description: "Dimensions: 24\" x 36\"",
  images: ["images/dm2616125-01.jpg"]
}
```

Item photos appear on catalog cards and in the item detail view. Selecting a card opens that item's detail view. Search checks the name, category, location, ticket number, and quantity.

## Furniture donation requests

The **Request furniture** button opens `request.html`. The form opens a prefilled email draft addressed to `page@tmservices.net`; the submitter must send that email to complete the request. The static website does not store form entries or confirm email delivery.

## Import inventory from a PDF

For a repeatable drop-folder workflow on Windows 10 or later:

1. Install Python 3 and the PDF image extraction dependency once by running `python -m pip install -r requirements.txt` from the project folder. Double-click `Set up PDF drop automation.bat`. This creates the `PDF Drop` and `PDF Review` folders, starts the watcher, and adds it to your Windows Startup folder for your Windows account.
2. Drop an inventory PDF into `PDF Drop`. The watcher waits for the copy to finish, automatically adds recognized items and photos to `catalog.js` and `images`, and moves the original PDF to `PDF Drop/Processed`. Photos for tickets already in the catalog are left unchanged during automatic imports, so an unreviewed PDF cannot alter their image mappings. A PowerShell window opens when processing finishes and stays open until you press Enter.
3. Review `catalog.js` and the images on your own time. Items whose category could not be confidently inferred are added under `Needs Review`, so you can find and correct them later.
4. The watcher then publishes automatically: `publish-catalog.ps1` mirrors `catalog.js` and `images` into a private clone (`%LOCALAPPDATA%\TMCatalogPublish`) and pushes to `main`, so GitHub Pages updates. To change or remove an item, edit `catalog.js` (delete its entry; delete unused photos from `images`) while the watcher runs and the change is pushed within seconds. Failed pushes retry every 5 minutes and are logged in `PDF Review/import-log.txt`. Git must be installed and signed in to GitHub (Git Credential Manager).

If the automatic watcher does not run, double-click `Manually convert PDF with review.bat` and choose the PDF. It automatically imports the items and photos, then opens a PowerShell completion window.

The importer uses Windows' built-in PDF renderer and OCR, plus Python, `pypdf`, and Pillow to extract embedded JPG/PNG photos. PDFs are processed locally. The watcher accepts PDFs regardless of filename; the importer recognizes the similar inventory format when item detail rows use ticket headings with a two-letter warehouse prefix followed by seven digits (for example, `DM2616125` or `CR2618512`). A cover page with only a `Donatable Items` heading has no item rows to convert. Drafts are retained in `PDF Review` for reference. Embedded photos for new tickets are moved into `images` and new ticket records are added directly to `catalog.js`; automatic imports update matching ticket locations but leave their existing photo mappings unchanged. To add photos to existing tickets, inspect and apply their draft entries with the review workflow. OCR can misread details; review the catalog and photos when convenient and correct anything needed. Items without a confident category are assigned `Needs Review`. Check `PDF Review/import-log.txt` for processing status or errors. A PDF that fails processing stays in `PDF Drop`; after correcting it, drop another copy under a new filename to retry.

The manual PowerShell commands are also available when needed. For a draft that contains all your checked entries, set the final `approveAll` value to `true` before applying:

```powershell
.\import-pdf.ps1 -PdfPath "C:\path\to\inventory.pdf" -ReviewPath ".\PDF Review\review.json"
.\import-pdf.ps1 -Apply -ReviewPath ".\PDF Review\review.json"
```

The PDF drop watcher shortcut is in your Windows Startup folder. If you move this project folder, rerun setup to update the shortcut.

## Publish with GitHub Pages

1. Add `index.html`, `styles.css`, `catalog.js`, and this README to the top level of your GitHub repository.
2. Commit and push your changes to the branch you use for the site (commonly `main`).
3. In the repository on GitHub, open **Settings → Pages**.
4. Under **Build and deployment**, choose **Deploy from a branch**.
5. Select your branch and the `/(root)` folder, then save.
6. Wait for GitHub Pages to finish deploying. The Pages settings will show your website URL.

After you change the catalog, commit and push again; GitHub Pages will publish the update.
