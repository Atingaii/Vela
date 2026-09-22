//! App-owned credentials stay in the OS vault and never appear in snapshots or JSON settings.
fn valid(id: &str) -> bool {
    !id.is_empty() && id.len() <= 100 && id.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-')
}
#[cfg(target_os = "macos")]
pub fn read(id: &str) -> Result<String, String> {
    use security_framework::item::{ItemClass, ItemSearchOptions, SearchResult};
    let result = ItemSearchOptions::new()
        .class(ItemClass::generic_password())
        .service("Vela")
        .account(id)
        .load_data(true)
        .skip_authenticated_items(true)
        .search()
        .map_err(|_| "找不到已保存的密钥")?;
    result
        .into_iter()
        .find_map(|r| {
            if let SearchResult::Data(b) = r {
                String::from_utf8(b).ok()
            } else {
                None
            }
        })
        .ok_or("找不到已保存的密钥".into())
}
#[cfg(windows)]
pub fn read(id: &str) -> Result<String, String> {
    use windows::{core::PCWSTR, Win32::Security::Credentials::*};
    let target: Vec<u16> = format!("Vela/{id}\0").encode_utf16().collect();
    let mut ptr = std::ptr::null_mut();
    unsafe {
        CredReadW(PCWSTR(target.as_ptr()), CRED_TYPE_GENERIC, 0, &mut ptr)
            .map_err(|_| "找不到已保存的密钥")?;
        let data =
            std::slice::from_raw_parts((*ptr).CredentialBlob, (*ptr).CredentialBlobSize as usize)
                .to_vec();
        CredFree(ptr.cast());
        String::from_utf8(data).map_err(|_| "密钥编码无效".into())
    }
}
#[cfg(not(any(windows, target_os = "macos")))]
pub fn read(_id: &str) -> Result<String, String> {
    Err("此平台未启用凭据保管库".into())
}

#[tauri::command]
pub fn save_provider_secret(id: String, secret: String) -> Result<(), String> {
    if !valid(&id) || secret.len() > 8192 || secret.contains(['\r', '\n']) {
        return Err("密钥格式无效".into());
    }
    #[cfg(target_os = "macos")]
    {
        use security_framework::passwords::{delete_generic_password, set_generic_password};
        if secret.is_empty() {
            delete_generic_password("Vela", &id).map_err(|_| "无法删除密钥".to_string())?;
        } else {
            set_generic_password("Vela", &id, secret.as_bytes())
                .map_err(|_| "无法保存密钥".to_string())?;
        }
    }
    #[cfg(windows)]
    {
        use windows::{
            core::{PCWSTR, PWSTR},
            Win32::Security::Credentials::*,
        };
        let mut target: Vec<u16> = format!("Vela/{id}\0").encode_utf16().collect();
        unsafe {
            if secret.is_empty() {
                CredDeleteW(PCWSTR(target.as_ptr()), CRED_TYPE_GENERIC, 0)
                    .map_err(|_| "无法删除密钥".to_string())?;
            } else {
                let credential = CREDENTIALW {
                    Type: CRED_TYPE_GENERIC,
                    TargetName: PWSTR(target.as_mut_ptr()),
                    CredentialBlobSize: secret.len() as u32,
                    CredentialBlob: secret.as_ptr() as *mut u8,
                    Persist: CRED_PERSIST_LOCAL_MACHINE,
                    ..Default::default()
                };
                CredWriteW(&credential, 0).map_err(|_| "无法保存密钥".to_string())?;
            }
        }
    }
    #[cfg(not(any(windows, target_os = "macos")))]
    return Err("此平台未启用凭据保管库，请通过环境变量配置".into());
    #[cfg(any(windows, target_os = "macos"))]
    {
        crate::providers::request(&id);
        Ok(())
    }
}
