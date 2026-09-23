#include "package.h"

#include <bcrypt.h>
#include <sddl.h>

#include <cstring>
#include <string>
#include <vector>

#include "update_public_key.h"

namespace {

// Le ZIP publie fait ~50 Mo ; la borne n'est la que pour qu'un chemin vers
// n'importe quoi d'enorme ne remplisse pas le disque du service.
constexpr ULONGLONG kMaxPackageBytes = 1ull << 30;

// Fin de repertoire central du ZIP, sans son commentaire.
constexpr DWORD kEocdSize = 22;
constexpr DWORD kMaxCommentSize = 0xFFFF;

// Commentaire du ZIP : magic + longueur de version (1 octet) + version +
// signature r||s. Voir scripts/sign-windows-update.ps1, qui l'ecrit.
constexpr char kSignatureMagic[] = "ONYXSIG1";
constexpr size_t kSignatureMagicSize = sizeof(kSignatureMagic) - 1;
constexpr size_t kSignatureSize = 64;
constexpr size_t kMaxVersionSize = 32;

// Ce que l'echange ne touche jamais : les fichiers de desinstallation d'Inno
// (unins000.exe/.dat) appartiennent a l'installation, pas a une version, et
// les dossiers de travail des mises a jour.
constexpr wchar_t kWorkPrefix[] = L".update-";

// SYSTEM et Administrateurs seulement, sans heritage du parent : la copie du
// paquet faite par le service ne doit pas etre lisible par l'utilisateur qui
// l'a demandee, sinon il suffirait de designer un fichier d'un autre pour le
// lire.
constexpr wchar_t kProtectedSddl[] = L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";

class Sha256 {
 public:
  Sha256() {
    if (BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(
            &algorithm_, BCRYPT_SHA256_ALGORITHM, nullptr, 0))) {
      BCryptCreateHash(algorithm_, &hash_, nullptr, 0, nullptr, 0, 0);
    }
  }
  ~Sha256() {
    if (hash_) BCryptDestroyHash(hash_);
    if (algorithm_) BCryptCloseAlgorithmProvider(algorithm_, 0);
  }
  Sha256(const Sha256&) = delete;
  Sha256& operator=(const Sha256&) = delete;

  bool Update(const void* data, ULONG size) {
    return hash_ && BCRYPT_SUCCESS(BCryptHashData(
                        hash_, static_cast<PUCHAR>(const_cast<void*>(data)),
                        size, 0));
  }
  bool Finish(unsigned char digest[32]) {
    return hash_ && BCRYPT_SUCCESS(BCryptFinishHash(hash_, digest, 32, 0));
  }

 private:
  BCRYPT_ALG_HANDLE algorithm_ = nullptr;
  BCRYPT_HASH_HANDLE hash_ = nullptr;
};

bool ReadAt(HANDLE file, ULONGLONG offset, void* buffer, DWORD size) {
  LARGE_INTEGER position;
  position.QuadPart = static_cast<LONGLONG>(offset);
  if (!SetFilePointerEx(file, position, nullptr, FILE_BEGIN)) return false;
  DWORD read = 0;
  return ReadFile(file, buffer, size, &read, nullptr) && read == size;
}

// Hache les [length] premiers octets du fichier.
bool HashPrefix(HANDLE file, ULONGLONG length, Sha256* hash) {
  LARGE_INTEGER start{};
  if (!SetFilePointerEx(file, start, nullptr, FILE_BEGIN)) return false;
  std::vector<unsigned char> buffer(1 << 20);
  while (length > 0) {
    const DWORD chunk = static_cast<DWORD>(
        length < buffer.size() ? length : buffer.size());
    DWORD read = 0;
    if (!ReadFile(file, buffer.data(), chunk, &read, nullptr) || read != chunk) {
      return false;
    }
    if (!hash->Update(buffer.data(), chunk)) return false;
    length -= chunk;
  }
  return true;
}

bool VerifySignature(const unsigned char digest[32],
                     const unsigned char* signature) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  if (!BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(
          &algorithm, BCRYPT_ECDSA_P256_ALGORITHM, nullptr, 0))) {
    return false;
  }
  bool valid = false;
  BCRYPT_KEY_HANDLE key = nullptr;
  if (BCRYPT_SUCCESS(BCryptImportKeyPair(
          algorithm, nullptr, BCRYPT_ECCPUBLIC_BLOB, &key,
          const_cast<PUCHAR>(kUpdatePublicKey), sizeof(kUpdatePublicKey), 0))) {
    valid = BCRYPT_SUCCESS(BCryptVerifySignature(
        key, nullptr, const_cast<PUCHAR>(digest), 32,
        const_cast<PUCHAR>(signature), static_cast<ULONG>(kSignatureSize), 0));
    BCryptDestroyKey(key);
  }
  BCryptCloseAlgorithmProvider(algorithm, 0);
  return valid;
}

bool IsVersionString(const std::string& version) {
  if (version.empty() || version.size() > kMaxVersionSize) return false;
  for (char c : version) {
    if (c != '.' && (c < '0' || c > '9')) return false;
  }
  return true;
}

// La signature couvre le ZIP tel qu'avant signature (commentaire vide) et la
// version : un paquet signe ne peut ni etre modifie ni se faire passer pour
// une autre version.
UpdateResult VerifyOpenPackage(HANDLE file, std::string* version) {
  LARGE_INTEGER size{};
  if (!GetFileSizeEx(file, &size) || size.QuadPart < kEocdSize ||
      static_cast<ULONGLONG>(size.QuadPart) > kMaxPackageBytes) {
    return kUpdateUnreadable;
  }
  const ULONGLONG total = static_cast<ULONGLONG>(size.QuadPart);
  const DWORD tail_size = static_cast<DWORD>(
      total < kEocdSize + kMaxCommentSize ? total : kEocdSize + kMaxCommentSize);
  std::vector<unsigned char> tail(tail_size);
  if (!ReadAt(file, total - tail_size, tail.data(), tail_size)) {
    return kUpdateUnreadable;
  }

  // La fin de repertoire central est le dernier element du fichier : on la
  // cherche depuis la fin, en exigeant que son commentaire tombe pile dessus.
  DWORD eocd = MAXDWORD;
  for (DWORD i = tail_size - kEocdSize + 1; i-- > 0;) {
    if (tail[i] == 0x50 && tail[i + 1] == 0x4b && tail[i + 2] == 0x05 &&
        tail[i + 3] == 0x06) {
      const DWORD comment_size = tail[i + 20] | (tail[i + 21] << 8);
      if (i + kEocdSize + comment_size == tail_size) {
        eocd = i;
        break;
      }
    }
  }
  if (eocd == MAXDWORD) return kUpdateUnreadable;

  const unsigned char* comment = tail.data() + eocd + kEocdSize;
  const size_t comment_size = tail_size - eocd - kEocdSize;
  if (comment_size < kSignatureMagicSize + 1 + kSignatureSize ||
      std::memcmp(comment, kSignatureMagic, kSignatureMagicSize) != 0) {
    return kUpdateBadSignature;
  }
  const size_t version_size = comment[kSignatureMagicSize];
  if (comment_size != kSignatureMagicSize + 1 + version_size + kSignatureSize) {
    return kUpdateBadSignature;
  }
  std::string signed_version(
      reinterpret_cast<const char*>(comment + kSignatureMagicSize + 1),
      version_size);
  if (!IsVersionString(signed_version)) return kUpdateBadSignature;
  const unsigned char* signature = comment + kSignatureMagicSize + 1 + version_size;

  // Le ZIP nu : tout jusqu'a la longueur du commentaire, remise a zero.
  Sha256 zip_hash;
  const unsigned char zero_length[2] = {0, 0};
  unsigned char zip_digest[32];
  const ULONGLONG eocd_offset = total - tail_size + eocd;
  if (!HashPrefix(file, eocd_offset + 20, &zip_hash) ||
      !zip_hash.Update(zero_length, 2) || !zip_hash.Finish(zip_digest)) {
    return kUpdateUnreadable;
  }

  static const char kHex[] = "0123456789abcdef";
  std::string message = "onyx-update-v1\n" + signed_version + "\n";
  for (unsigned char byte : zip_digest) {
    message += kHex[byte >> 4];
    message += kHex[byte & 0xF];
  }
  Sha256 message_hash;
  unsigned char message_digest[32];
  if (!message_hash.Update(message.data(), static_cast<ULONG>(message.size())) ||
      !message_hash.Finish(message_digest)) {
    return kUpdateUnreadable;
  }
  if (!VerifySignature(message_digest, signature)) return kUpdateBadSignature;

  *version = signed_version;
  return kUpdateOk;
}

UpdateResult VerifyPackage(const std::wstring& path, std::string* version) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                            nullptr, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) return kUpdateUnreadable;
  const UpdateResult result = VerifyOpenPackage(file, version);
  CloseHandle(file);
  return result;
}

// "1.2.3" -> {1, 2, 3}. Exactement trois nombres, comme les tags vX.Y.Z.
bool ParseVersion(const std::string& text, unsigned parts[3]) {
  size_t start = 0;
  for (int i = 0; i < 3; ++i) {
    const size_t end = i < 2 ? text.find('.', start) : text.size();
    if (end == std::string::npos || end == start || end - start > 9) {
      return false;
    }
    parts[i] = 0;
    for (size_t j = start; j < end; ++j) {
      if (text[j] < '0' || text[j] > '9') return false;
      parts[i] = parts[i] * 10 + static_cast<unsigned>(text[j] - '0');
    }
    start = end + 1;
  }
  return true;
}

// Version de l'app installee, lue dans les ressources d'app.exe : le build
// Flutter y ecrit --build-name. Le quatrieme nombre (numero de build) n'entre
// pas dans la comparaison, pas plus que dans le nom des artefacts.
bool InstalledVersion(const std::wstring& exe, unsigned parts[3]) {
  DWORD ignored = 0;
  const DWORD size = GetFileVersionInfoSizeW(exe.c_str(), &ignored);
  if (size == 0) return false;
  std::vector<unsigned char> data(size);
  if (!GetFileVersionInfoW(exe.c_str(), 0, size, data.data())) return false;
  VS_FIXEDFILEINFO* info = nullptr;
  UINT info_size = 0;
  if (!VerQueryValueW(data.data(), L"\\", reinterpret_cast<void**>(&info),
                      &info_size) ||
      info_size < sizeof(VS_FIXEDFILEINFO)) {
    return false;
  }
  parts[0] = HIWORD(info->dwFileVersionMS);
  parts[1] = LOWORD(info->dwFileVersionMS);
  parts[2] = HIWORD(info->dwFileVersionLS);
  return true;
}

// Refuser une version plus ancienne, meme signee : sinon on pourrait faire
// reinstaller une version dont une faille est connue.
bool IsNewer(const std::string& version, const std::wstring& app_dir) {
  unsigned candidate[3];
  if (!ParseVersion(version, candidate)) return false;
  unsigned installed[3];
  // app.exe illisible : rien a proteger, l'installation est de toute facon a
  // reparer.
  if (!InstalledVersion(app_dir + L"\\app.exe", installed)) return true;
  for (int i = 0; i < 3; ++i) {
    if (candidate[i] != installed[i]) return candidate[i] > installed[i];
  }
  return false;
}

std::vector<std::wstring> ListEntries(const std::wstring& dir) {
  std::vector<std::wstring> names;
  WIN32_FIND_DATAW data;
  HANDLE find = FindFirstFileW((dir + L"\\*").c_str(), &data);
  if (find == INVALID_HANDLE_VALUE) return names;
  do {
    const std::wstring name = data.cFileName;
    if (name != L"." && name != L"..") names.push_back(name);
  } while (FindNextFileW(find, &data));
  FindClose(find);
  return names;
}

// Suppression recursive qui ne suit jamais un lien : un point de jonction est
// retire, pas ce vers quoi il pointe. Best effort — un fichier encore ouvert
// (l'exe d'une autre session) reste, et part a la mise a jour suivante.
void DeleteTree(const std::wstring& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES) return;
  if (attributes & FILE_ATTRIBUTE_READONLY) {
    SetFileAttributesW(path.c_str(), attributes & ~FILE_ATTRIBUTE_READONLY);
  }
  if (!(attributes & FILE_ATTRIBUTE_DIRECTORY)) {
    DeleteFileW(path.c_str());
    return;
  }
  if (!(attributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
    for (const std::wstring& name : ListEntries(path)) {
      DeleteTree(path + L"\\" + name);
    }
  }
  RemoveDirectoryW(path.c_str());
}

bool StartsWith(const std::wstring& text, const wchar_t* prefix) {
  return text.compare(0, wcslen(prefix), prefix) == 0;
}

bool IsKeptOnSwap(const std::wstring& name) {
  return StartsWith(name, kWorkPrefix) ||
         _wcsnicmp(name.c_str(), L"unins", 5) == 0;
}

// Un antivirus qui inspecte un fichier fraichement extrait le tient ouvert
// quelques centaines de millisecondes : on reessaie avant de conclure qu'il
// est vraiment utilise.
bool MoveWithRetry(const std::wstring& from, const std::wstring& to) {
  for (int attempt = 0; attempt < 20; ++attempt) {
    if (MoveFileExW(from.c_str(), to.c_str(), 0)) return true;
    Sleep(250);
  }
  return false;
}

// Un exe ou une DLL en cours d'execution ne peut pas etre ecrase, mais peut
// etre renomme : l'ancienne version part entiere dans [old_dir] (y compris
// onyx-updater.exe lui-meme, qui tourne), la nouvelle prend sa place. Au
// moindre echec, chaque deplacement est defait dans l'ordre inverse.
UpdateResult Swap(const std::wstring& app_dir, const std::wstring& new_dir,
                  const std::wstring& old_dir) {
  if (!CreateDirectoryW(old_dir.c_str(), nullptr)) return kUpdateInUse;

  std::vector<std::wstring> moved_out;
  for (const std::wstring& name : ListEntries(app_dir)) {
    if (IsKeptOnSwap(name)) continue;
    if (!MoveWithRetry(app_dir + L"\\" + name, old_dir + L"\\" + name)) {
      bool restored = true;
      for (auto it = moved_out.rbegin(); it != moved_out.rend(); ++it) {
        restored &= MoveWithRetry(old_dir + L"\\" + *it, app_dir + L"\\" + *it);
      }
      return restored ? kUpdateInUse : kUpdateBroken;
    }
    moved_out.push_back(name);
  }

  std::vector<std::wstring> moved_in;
  for (const std::wstring& name : ListEntries(new_dir)) {
    if (!MoveWithRetry(new_dir + L"\\" + name, app_dir + L"\\" + name)) {
      bool restored = true;
      for (auto it = moved_in.rbegin(); it != moved_in.rend(); ++it) {
        restored &= MoveWithRetry(app_dir + L"\\" + *it, new_dir + L"\\" + *it);
      }
      for (auto it = moved_out.rbegin(); it != moved_out.rend(); ++it) {
        restored &= MoveWithRetry(old_dir + L"\\" + *it, app_dir + L"\\" + *it);
      }
      return restored ? kUpdateInUse : kUpdateBroken;
    }
    moved_in.push_back(name);
  }
  return kUpdateOk;
}

// tar.exe fait partie de Windows depuis 10 (1803) et lit les ZIP : pas
// d'inflate a embarquer. Il ne voit le paquet qu'une fois la signature
// verifiee.
bool Extract(const std::wstring& zip, const std::wstring& destination) {
  wchar_t system_dir[MAX_PATH];
  const UINT length = GetSystemDirectoryW(system_dir, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) return false;
  const std::wstring tar = std::wstring(system_dir) + L"\\tar.exe";
  std::wstring command = L"\"" + tar + L"\" -xf \"" + zip + L"\" -C \"" +
                         destination + L"\"";

  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(tar.c_str(), command.data(), nullptr, nullptr, FALSE,
                      CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process)) {
    return false;
  }
  CloseHandle(process.hThread);
  DWORD exit_code = 1;
  if (WaitForSingleObject(process.hProcess, 10 * 60 * 1000) == WAIT_OBJECT_0) {
    GetExitCodeProcess(process.hProcess, &exit_code);
  } else {
    TerminateProcess(process.hProcess, 1);
  }
  CloseHandle(process.hProcess);
  return exit_code == 0;
}

// Seul un chemin local absolu est accepte. Un chemin UNC ferait
// s'authentifier le compte machine aupres d'un serveur choisi par
// l'appelant ; un chemin de peripherique n'est pas un fichier.
bool IsLocalPath(const std::wstring& path) {
  return path.size() > 3 &&
         ((path[0] >= L'A' && path[0] <= L'Z') ||
          (path[0] >= L'a' && path[0] <= L'z')) &&
         path[1] == L':' && path[2] == L'\\';
}

bool CreateProtectedDirectory(const std::wstring& path) {
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          kProtectedSddl, SDDL_REVISION_1, &descriptor, nullptr)) {
    return false;
  }
  SECURITY_ATTRIBUTES attributes{sizeof(attributes), descriptor, FALSE};
  const bool created = CreateDirectoryW(path.c_str(), &attributes) != 0;
  LocalFree(descriptor);
  return created;
}

// Copie, verifie, extrait : rien n'est lu dans le paquet d'origine apres la
// copie, que l'appelant pourrait remplacer entre-temps.
UpdateResult Stage(const std::wstring& package, const std::wstring& staging,
                   const std::wstring& app_dir, bool as_service) {
  WIN32_FILE_ATTRIBUTE_DATA source{};
  if (!IsLocalPath(package) ||
      !GetFileAttributesExW(package.c_str(), GetFileExInfoStandard, &source) ||
      (source.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
      ((static_cast<ULONGLONG>(source.nFileSizeHigh) << 32) |
       source.nFileSizeLow) > kMaxPackageBytes) {
    return kUpdateUnreadable;
  }

  const std::wstring package_dir = staging + L"\\package";
  const bool created = as_service
                           ? CreateProtectedDirectory(package_dir)
                           : CreateDirectoryW(package_dir.c_str(), nullptr) != 0;
  const std::wstring zip = package_dir + L"\\update.zip";
  if (!created || !CopyFileW(package.c_str(), zip.c_str(), FALSE)) {
    return kUpdateUnreadable;
  }

  std::string version;
  const UpdateResult verified = VerifyPackage(zip, &version);
  if (verified != kUpdateOk) return verified;
  if (!IsNewer(version, app_dir)) return kUpdateNotNewer;

  const std::wstring files = staging + L"\\files";
  if (!CreateDirectoryW(files.c_str(), nullptr) || !Extract(zip, files) ||
      GetFileAttributesW((files + L"\\app.exe").c_str()) ==
          INVALID_FILE_ATTRIBUTES) {
    return kUpdateExtractFailed;
  }
  return kUpdateOk;
}

}  // namespace

std::wstring ModulePath() {
  std::wstring path(MAX_PATH, L'\0');
  for (;;) {
    const DWORD length = GetModuleFileNameW(
        nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (length == 0) return std::wstring();
    if (length < path.size()) {
      path.resize(length);
      return path;
    }
    path.resize(path.size() * 2);
  }
}

std::wstring ModuleDirectory() {
  const std::wstring path = ModulePath();
  return path.substr(0, path.find_last_of(L'\\'));
}

UpdateResult ApplyUpdate(const std::wstring& package,
                         const std::wstring& app_dir,
                         bool as_service) {
  // Restes des mises a jour precedentes : l'ancienne version, qu'un exe
  // encore ouvert empechait de supprimer sur le moment.
  for (const std::wstring& name : ListEntries(app_dir)) {
    if (StartsWith(name, kWorkPrefix)) DeleteTree(app_dir + L"\\" + name);
  }

  const std::wstring tag = std::to_wstring(GetTickCount64());
  const std::wstring staging = app_dir + L"\\.update-new-" + tag;
  const std::wstring old_dir = app_dir + L"\\.update-old-" + tag;
  if (!CreateDirectoryW(staging.c_str(), nullptr)) return kUpdateUnreadable;

  UpdateResult result = Stage(package, staging, app_dir, as_service);
  if (result == kUpdateOk) result = Swap(app_dir, staging + L"\\files", old_dir);

  // Installation cassee : ce qui reste de l'ancienne version n'existe plus
  // qu'ici, on n'y touche pas.
  if (result == kUpdateBroken) return result;
  DeleteTree(staging);
  // En cas de succes, l'ancienne version ; sinon, le dossier vide que Swap a
  // pu laisser apres avoir tout remis en place.
  DeleteTree(old_dir);
  return result;
}
