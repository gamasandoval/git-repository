#!/usr/bin/env python3

import os
import sys
import time
import re
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC


def print_number_challenge(driver):
    print("Looking for Okta number challenge...")
    text = driver.find_element(By.TAG_NAME, "body").text
    numbers = re.findall(r"\b\d{2,3}\b", text)
    if numbers:
        print("Possible numbers:")
        for n in set(numbers):
            print(f" -> {n}")
    else:
        print("No number challenge detected.")


def wait_for_mfa(driver, host):
    print("Waiting for MFA approval...")
    for _ in range(60):
        if host in driver.current_url:
            return True
        cookies = driver.get_cookies()
        for c in cookies:
            if "SVPNCOOKIE" in c.get("name", ""):
                return True
        time.sleep(2)
    return False


def main():
    if len(sys.argv) != 4:
        print("Usage: saml_connection.py <host> <user> <token_file>")
        sys.exit(1)

    host, username, token_file = sys.argv[1], sys.argv[2], sys.argv[3]
    password = os.environ.get("VPN_PASS")

    if not password:
        print("VPN_PASS not set")
        sys.exit(1)

    options = Options()
    options.add_argument("--headless=new")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--ignore-certificate-errors")

    driver = webdriver.Chrome(
        service=Service("/usr/local/bin/chromedriver"),
        options=options,
    )

    wait = WebDriverWait(driver, 60)

    try:
        driver.get(f"https://{host}/remote/saml/start")

        wait.until(EC.presence_of_element_located(
            (By.CSS_SELECTOR, "input[id^='input'], input[type='email']")
        )).send_keys(username)

        wait.until(EC.element_to_be_clickable(
            (By.CSS_SELECTOR, ".button-primary")
        )).click()

        wait.until(EC.presence_of_element_located(
            (By.CSS_SELECTOR, "input[type='password']")
        )).send_keys(password)

        wait.until(EC.element_to_be_clickable(
            (By.CSS_SELECTOR, ".button-primary")
        )).click()

        try:
            wait.until(EC.element_to_be_clickable(
                (By.XPATH, "//div[contains(@data-se, 'okta_verify-push')]/a")
            )).click()
        except:
            pass

        time.sleep(3)
        print_number_challenge(driver)
        wait_for_mfa(driver, host)

        cookies = driver.get_cookies()
        for c in cookies:
            if "SVPNCOOKIE" in c.get("name", ""):
                with open(token_file, "w") as f:
                    f.write(c["value"])
                print("Token saved")
                return

        print("SVPNCOOKIE not found")
        sys.exit(1)

    finally:
        driver.quit()


if __name__ == "__main__":
    main()

