<?php
/**
 * update.php - PBX Extension Update Script
 * cPanel Server
 *
 * এই স্ক্রিপ্টটি ডাটাবেসের `extensions` টেবিল থেকে একটি এক্সটেনশনের তথ্য এনে
 * একটি ফর্মে দেখায় এবং ব্যবহারকারীর পরিবর্তনগুলো নিরাপদে (Prepared Statements
 * ব্যবহার করে) ডাটাবেসে সংরক্ষণ করে।
 *
 * ব্যবহার:
 *   - এডিট করতে: update.php?id=1  (এখানে 1 হলো extensions টেবিলের `id`)
 *   - অথবা: update.php?extension=1001
 */

require_once __DIR__ . '/db.php'; // আপনার ডাটাবেস কানেকশন ফাইল

// ------------------------------------------------------------------
// ১. ডাট demand: কোন এক্সটেনশনটি এডিট করতে হবে তা নির্ধারণ
// ------------------------------------------------------------------
$id = isset($_GET['id']) ? (int)$_GET['id'] : 0;
$extensionNumber = isset($_GET['extension']) ? trim($_GET['extension']) : '';

$extension = null;
$error = '';
$success = '';

// ------------------------------------------------------------------
// ২. ডাটাবেস থেকে এক্সটেনশনের বর্তমান তথ্য আনা
// ------------------------------------------------------------------
if ($id > 0 || $extensionNumber !== '') {
    try {
        if ($id > 0) {
            $stmt = db()->prepare("SELECT * FROM extensions WHERE id = ? LIMIT 1");
            $stmt->execute([$id]);
        } else {
            $stmt = db()->prepare("SELECT * FROM extensions WHERE extension = ? LIMIT 1");
            $stmt->execute([$extensionNumber]);
        }
        $extension = $stmt->fetch();
        if (!$extension) {
            $error = 'এক্সটেনশন খুঁজে পাওয়া যায়নি।';
        }
    } catch (PDOException $e) {
        $error = 'ডাটাবেস ত্রুটি: ' . $e->getMessage();
    }
} else {
    $error = 'কোনো এক্সটেনশন আইডি বা নম্বর দেওয়া হয়নি।';
}

// ------------------------------------------------------------------
// ৩. ফর্ম সাবমিট হলে (POST) ডাটাবেস আপডেট করা
// ------------------------------------------------------------------
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $extension) {
    // ফর্ম থেকে ডেটা নেওয়া
    $newExtension = trim($_POST['extension'] ?? '');
    $newPassword  = $_POST['password'] ?? '';
    $newName      = trim($_POST['name'] ?? '');
    $newEmail     = trim($_POST['email'] ?? '');
    $newCallerid  = trim($_POST['callerid'] ?? '');
    $newEnabled   = $_POST['enabled'] ?? 'yes';

    // ভ্যালিডেশন
    $validationErrors = [];

    if ($newExtension === '') {
        $validationErrors[] = 'এক্সটেনশন নম্বর খালি রাখা যাবে না।';
    } elseif (!preg_match('/^[0-9]{2,6}$/', $newExtension)) {
        $validationErrors[] = 'এক্সটেনশন নম্বর ২-৬ ডিজিটের হতে হবে।';
    }

    // পাসওয়ার্ড খালি থাকলে পুরোনোটি রাখা হবে
    if ($newPassword !== '' && strlen($newPassword) < 4) {
        $validationErrors[] = 'পাসওয়ার্ড কমপক্ষে ৪ অক্ষরের হতে হবে।';
    }

    if ($newEmail !== '' && !filter_var($newEmail, FILTER_VALIDATE_EMAIL)) {
        $validationErrors[] = 'ইমেইল ঠিকানা সঠিক নয়।';
    }

    if ($newEnabled !== 'yes' && $newEnabled !== 'no') {
        $newEnabled = 'yes';
    }

    // যদি কোনো ভুল না থাকে, তবে আপডেট করুন
    if (empty($validationErrors)) {
        try {
            // পাসওয়ার্ড পরিবর্তন করতে হবে কিনা
            $passwordToSave = $newPassword !== '' ? $newPassword : $extension['password'];

            // CallerID ফাঁকা থাকলে নাম ও এক্সটেনশন দিয়ে অটো-জেনারেট
            if ($newCallerid === '') {
                $newCallerid = $newName !== '' ? "{$newName} <{$newExtension}>" : $newExtension;
            }

            $sql = "UPDATE extensions SET
                        extension = :extension,
                        password  = :password,
                        name      = :name,
                        email     = :email,
                        callerid  = :callerid,
                        enabled   = :enabled
                    WHERE id = :id";
            $stmt = db()->prepare($sql);
            $stmt->execute([
                ':extension' => $newExtension,
                ':password'  => $passwordToSave,
                ':name'      => $newName,
                ':email'     => $newEmail,
                ':callerid'  => $newCallerid,
                ':enabled'   => $newEnabled,
                ':id'        => $extension['id']
            ]);

            $success = 'এক্সটেনশন সফলভাবে আপডেট হয়েছে।';
            // আপডেটের পর নতুন তথ্য লোড করুন
            $stmt = db()->prepare("SELECT * FROM extensions WHERE id = ? LIMIT 1");
            $stmt->execute([$extension['id']]);
            $extension = $stmt->fetch();
        } catch (PDOException $e) {
            $error = 'আপডেট করতে ব্যর্থ: ' . $e->getMessage();
        }
    } else {
        $error = implode('<br>', $validationErrors);
    }
}

// ------------------------------------------------------------------
// ৪. HTML ফর্ম
// ------------------------------------------------------------------
?>
<!DOCTYPE html>
<html lang="bn">
<head>
    <meta charset="UTF-8">
    <title>এক্সটেনশন আপডেট - PBX</title>
    <style>
        body { font-family: sans-serif; background: #f4f6f9; margin: 2rem; }
        .container { max-width: 600px; margin: auto; background: #fff; padding: 2rem; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,.1); }
        h1 { color: #2c3e50; border-bottom: 2px solid #3498db; padding-bottom: .5rem; }
        .form-group { margin-bottom: 1rem; }
        label { display: block; font-weight: 600; margin-bottom: .3rem; color: #34495e; }
        input[type="text"], input[type="password"], input[type="email"], select {
            width: 100%; padding: .6rem; border: 1px solid #bdc3c7; border-radius: 4px; font-size: 1rem;
            box-sizing: border-box;
        }
        input[type="text"]:focus, input[type="password"]:focus, input[type="email"]:focus, select:focus {
            border-color: #3498db; outline: none;
        }
        .btn { display: inline-block; background: #3498db; color: #fff; padding: .7rem 1.5rem; border: none; border-radius: 4px; font-size: 1rem; cursor: pointer; }
        .btn:hover { background: #2980b9; }
        .alert { padding: .8rem 1rem; border-radius: 4px; margin-bottom: 1rem; }
        .alert-error { background: #fdecea; color: #c0392b; border-left: 4px solid #c0392b; }
        .alert-success { background: #eafaf1; color: #27ae60; border-left: 4px solid #27ae60; }
        .back-link { display: inline-block; margin-top: 1rem; color: #3498db; text-decoration: none; }
    </style>
</head>
<body>
<div class="container">
    <h1>🔧 এক্সটেনশন আপডেট</h1>

    <?php if ($error): ?>
        <div class="alert alert-error"><?= $error ?></div>
    <?php endif; ?>

    <?php if ($success): ?>
        <div class="alert alert-success"><?= $success ?></div>
    <?php endif; ?>

    <?php if ($extension): ?>
        <form method="post">
            <div class="form-group">
                <label for="extension">এক্সটেনশন নম্বর *</label>
                <input type="text" id="extension" name="extension"
                       value="<?= htmlspecialchars($extension['extension']) ?>" required
                       pattern="[0-9]{2,6}" title="২-৬ ডিজিটের নম্বর দিন">
            </div>

            <div class="form-group">
                <label for="password">পাসওয়ার্ড (পরিবর্তন না করতে চাইলে খালি রাখুন)</label>
                <input type="password" id="password" name="password"
                       placeholder="নতুন পাসওয়ার্ড দিন">
            </div>

            <div class="form-group">
                <label for="name">নাম</label>
                <input type="text" id="name" name="name"
                       value="<?= htmlspecialchars($extension['name'] ?? '') ?>">
            </div>

            <div class="form-group">
                <label for="email">ইমেইল</label>
                <input type="email" id="email" name="email"
                       value="<?= htmlspecialchars($extension['email'] ?? '') ?>">
            </div>

            <div class="form-group">
                <label for="callerid">CallerID (খালি রাখলে অটো-জেনারেট হবে)</label>
                <input type="text" id="callerid" name="callerid"
                       value="<?= htmlspecialchars($extension['callerid'] ?? '') ?>">
            </div>

            <div class="form-group">
                <label for="enabled">সক্রিয়/নিষ্ক্রিয়</label>
                <select id="enabled" name="enabled">
                    <option value="yes" <?= $extension['enabled'] === 'yes' ? 'selected' : '' ?>>সক্রিয় (Yes)</option>
                    <option value="no"  <?= $extension['enabled'] === 'no'  ? 'selected' : '' ?>>নিষ্ক্রিয় (No)</option>
                </select>
            </div>

            <button type="submit" class="btn">💾 আপডেট সংরক্ষণ করুন</button>
        </form>
    <?php elseif (!$error): ?>
        <p>কোনো এক্সটেনশন নির্বাচন করা হয়নি।</p>
    <?php endif; ?>

    <a href="list.php" class="back-link">← এক্সটেনশন তালিকায় ফিরে যান</a>
</div>
</body>
</html>
