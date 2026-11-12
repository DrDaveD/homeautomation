// Written by ChatGPT from prompts by Dave Dykstra 11/11/26 
//
// Dependencies (Debian 13 / Trixie):
//
//   sudo apt install nodejs npm chromium poppler-utils
//
//   mkdir comed-scraper
//   cd comed-scraper
//   npm init -y
//   npm install playwright
//
// Playwright uses Debian's system Chromium:
//   executablePath: '/usr/bin/chromium'
//
// Run:
//   node comed-rates.js


const { chromium } = require('playwright');
const fs = require('fs');
const { execFileSync } = require('child_process');

const PAGE_URL =
    'https://www.comed.com/currentratestariffsresidentialdeliveryrates';

const TARGET =
    'Residential Single Family Without Electric Space Heat Delivery Class';

async function getPdfUrl() {
    const browser = await chromium.launch({
        headless: true,
        executablePath: '/usr/bin/chromium'
    });

    try {
        const page = await browser.newPage();

        console.log('Opening ComEd rates page...');

        await page.goto(PAGE_URL, {
            waitUntil: 'domcontentloaded',
            timeout: 90000
        });

        // ComEd redirects to its PDF using JavaScript.
        await page.waitForURL(
            url => /\.pdf(?:$|\?)/i.test(url.href),
            { timeout: 30000 }
        );

        const pdfUrl = page.url();
        console.log('PDF URL:', pdfUrl);

        return pdfUrl;

    } finally {
        await browser.close();
    }
}

async function downloadPdf(url) {
    console.log('Downloading PDF...');

    const response = await fetch(url);

    if (!response.ok) {
        throw new Error(`PDF download failed: HTTP ${response.status}`);
    }

    const buffer = Buffer.from(await response.arrayBuffer());

    if (buffer.subarray(0, 4).toString() !== '%PDF') {
        throw new Error('Downloaded document is not a PDF.');
    }

    fs.writeFileSync('comed-rates.pdf', buffer);

    console.log(`Downloaded ${buffer.length} bytes.`);
}


function extractRates() {
    console.log('Extracting PDF text...');

    const text = execFileSync(
        'pdftotext',
        ['-layout', 'comed-rates.pdf', '-'],
        { encoding: 'utf8' }
    );

    const lines = text.split('\n');

    // Find the beginning of the requested delivery class.
    // Its name is split across multiple physical PDF lines.
    let start = -1;

    for (let i = 0; i < lines.length - 3; i++) {
        const block = lines.slice(i, i + 4).join(' ');

        if (
            /Residential Single/i.test(lines[i]) &&
            /Morning/i.test(lines[i]) &&
            /Family Without Electric/i.test(block) &&
            /Space Heat Delivery/i.test(block) &&
            /\bClass\b/i.test(block)
        ) {
            start = i;
            break;
        }
    }

    if (start === -1) {
        throw new Error(
            'Could not identify the wrapped residential delivery class.'
        );
    }

    console.log(`Delivery class found at text line ${start + 1}`);

    const expected = [
        'Morning',
        'Mid-Day Peak',
        'Evening',
        'Overnight'
    ];

    const rates = [];

    // Read the four rows belonging to this delivery class.
    for (let i = start; i < Math.min(start + 4, lines.length); i++) {
        const line = lines[i];

        const periodMatch = line.match(
            /\b(Morning|Mid[-–]Day Peak|Evening|Overnight)\b/i
        );

        if (!periodMatch) continue;

        const amounts = line.match(
            /\(?-?\$?\d+\.\d{5}\)?/g
        );

        if (!amounts) {
            throw new Error(
                `No dollar amounts found on line ${i + 1}`
            );
        }

        const period = periodMatch[1]
            .replace(/[-–]/, '-');

        const expectedPeriod = expected[rates.length];

        if (period.toLowerCase() !== expectedPeriod.toLowerCase()) {
            throw new Error(
                `Expected ${expectedPeriod}, found ${period}`
            );
        }

        rates.push({
            period,
            rate: amounts[amounts.length - 1]
        });
    }

    if (rates.length !== 4) {
        console.log('Relevant PDF lines:');
        console.log(lines.slice(start, start + 8).join('\n'));

        throw new Error(
            `Expected four rates, found ${rates.length}.`
        );
    }

    return rates;
}


function saveRatesJSON(rates, pdfUrl) {
    const expected = [
        'Morning',
        'Mid-Day Peak',
        'Evening',
        'Overnight'
    ];

    // Validate all four rates before writing anything.
    if (rates.length !== 4) {
        throw new Error('Expected exactly four rates. JSON not updated.');
    }

    const values = {};

    for (let i = 0; i < expected.length; i++) {
        const item = rates[i];

        if (item.period !== expected[i]) {
            throw new Error(
                `Expected ${expected[i]}, got ${item.period}. JSON not updated.`
            );
        }

        const dollars = parseFloat(
            item.rate.replace(/[$,]/g, '')
        );

        if (!Number.isFinite(dollars) || dollars <= 0) {
            throw new Error(
                `Invalid rate for ${item.period}. JSON not updated.`
            );
        }

        const key = expected[i]
            .toLowerCase()
            .replace(/-/g, '_')
            .replace(/ /g, '_');

        values[key] = Number((dollars * 100).toFixed(5));
    }

    // Construct the complete output in memory.
    const output = {
        retrieved: new Date().toISOString(),
        delivery_class:
            'Residential Single Family Without Electric Space Heat',
        unit: 'cents_per_kWh',
        pdf_url: pdfUrl,
        rates: values
    };

    // Write to a temporary file first.
    const tempFile = 'comed-rates.json.tmp';
    const finalFile = 'comed-rates.json';

    fs.writeFileSync(
        tempFile,
        JSON.stringify(output, null, 2) + '\n'
    );

    // Atomic replacement: the old JSON remains intact until
    // the new, validated JSON is ready.
    fs.renameSync(tempFile, finalFile);

    console.log('\nSuccessfully updated comed-rates.json');
}

async function main() {
    const pdfUrl = await getPdfUrl();

    await downloadPdf(pdfUrl);

    const rates = extractRates();
    saveRatesJSON(rates, pdfUrl);

    console.log('\nComEd Residential Delivery Rates');
    console.log(TARGET);
    console.log('----------------------------------------');

    for (const item of rates) {
        console.log(
            `${item.period.padEnd(14)} ${item.rate}/kWh`
        );
    }

    console.log('\nPDF saved as comed-rates.pdf');
}

main().catch(error => {
    console.error('\nERROR:', error.message);
    process.exitCode = 1;
});

