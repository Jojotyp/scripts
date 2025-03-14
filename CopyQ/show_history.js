let cutoffCharNr = 46;

// Get the last 5 items from the history
// Get the last 5 items from the history
let itemCount = Math.min(count(), 5);
let history = [];
for (let i = 0; i < itemCount; ++i) {
    let itemStr = str(cread(i));
    if (itemStr.length > 50) {
        itemStr = itemStr.substring(0, cutoffCharNr) + ' ...';
    }
    history.push(itemStr);
}

// Display the history in a popup
popup("Clipboard History", history.join("\n-----------------------------------------------------------------\n"), 6000);
itemStr.substring(0, cutoffCharNr)
ccClipboard HistoryClipboard HistorycStr.Str.