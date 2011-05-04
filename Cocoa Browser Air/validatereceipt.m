#import "validatereceipt.h"

#import <IOKit/IOKitLib.h>
#import <Foundation/Foundation.h>

#import <Security/Security.h>

#include <openssl/pkcs7.h>
#include <openssl/objects.h>
#include <openssl/sha.h>
#include <openssl/x509.h>
#include <openssl/err.h>


#define VRCFRelease(object) if(object) CFRelease(object)

NSString *kReceiptBundleIdentifier = @"BundleIdentifier";
NSString *kReceiptBundleIdentifierData = @"BundleIdentifierData";
NSString *kReceiptVersion = @"Version";
NSString *kReceiptOpaqueValue = @"OpaqueValue";
NSString *kReceiptHash = @"Hash";


NSData *appleRootCert()
{
	OSStatus status;

	SecKeychainRef keychain = nil;
	status = SecKeychainOpen("/System/Library/Keychains/SystemRootCertificates.keychain", &keychain);
	if (status) {
		VRCFRelease(keychain);
		return nil;
	}

	CFArrayRef searchList = CFArrayCreate(kCFAllocatorDefault, (const void **)&keychain, 1, &kCFTypeArrayCallBacks);

	// For some reason we get a malloc reference underflow warning message when garbage collection
	// is on. Perhaps a bug in SecKeychainOpen where the keychain reference isn't actually retained
	// in GC?
#ifndef __OBJC_GC__
	VRCFRelease(keychain);
#endif

	SecKeychainSearchRef searchRef = nil;
	status = SecKeychainSearchCreateFromAttributes(searchList, kSecCertificateItemClass, NULL, &searchRef);
	if (status) {
		VRCFRelease(searchRef);
		VRCFRelease(searchList);
		return nil;
	}

	SecKeychainItemRef itemRef = nil;
	NSData *resultData = nil;

	while (SecKeychainSearchCopyNext(searchRef, &itemRef) == noErr && !resultData) {
		// Grab the name of the certificate
		SecKeychainAttributeList list;
		SecKeychainAttribute attributes[1];

		attributes[0].tag = kSecLabelItemAttr;

		list.count = 1;
		list.attr = attributes;

		SecKeychainItemCopyContent(itemRef, nil, &list, nil, nil);
        NSString *name = [[NSString alloc] initWithBytesNoCopy:attributes[0].data length:attributes[0].length encoding:NSUTF8StringEncoding freeWhenDone:NO];

		if ([name isEqualToString:@"Apple Root CA"]) {
			CSSM_DATA certData;
			SecCertificateGetData((SecCertificateRef)itemRef, &certData);
			resultData = [NSData dataWithBytes:certData.Data length:certData.Length];
		}
		
		SecKeychainItemFreeContent(&list, NULL);

		if (itemRef) {
			VRCFRelease(itemRef);
        }

		[name release];
	}

	VRCFRelease(searchList);
	VRCFRelease(searchRef);

	return resultData;
}


NSDictionary *dictionaryWithAppStoreReceipt(NSURL *url)
{
	NSData *rootCertData = appleRootCert();

	enum ATTRIBUTES {
		ATTR_START = 1,
		BUNDLE_ID,
		VERSION,
		OPAQUE_VALUE,
		HASH,
		ATTR_END
	};

	ERR_load_PKCS7_strings();
	ERR_load_X509_strings();
	OpenSSL_add_all_digests();

	// Expected input is a PKCS7 container with signed data containing
	// an ASN.1 SET of SEQUENCE structures. Each SEQUENCE contains
	// two INTEGERS and an OCTET STRING.

	const char *receiptPath = [[[url path] stringByStandardizingPath] fileSystemRepresentation];
	FILE *fp = fopen(receiptPath, "rb");
	if (fp == NULL) {
		return nil;
    }

	PKCS7 *p7 = d2i_PKCS7_fp(fp, NULL);
	fclose(fp);

	// Check if the receipt file was invalid (otherwise we go crashing and burning)
	if (p7 == NULL) {
		return nil;
	}

	if (!PKCS7_type_is_signed(p7)) {
		PKCS7_free(p7);
		return nil;
	}

	if (!PKCS7_type_is_data(p7->d.sign->contents)) {
		PKCS7_free(p7);
		return nil;
	}

	int verifyReturnValue = 0;
	X509_STORE *store = X509_STORE_new();
	if (store) {
		const unsigned char *data = (unsigned char *)(rootCertData.bytes);
		X509 *appleCA = d2i_X509(NULL, &data, (long)rootCertData.length);
		if (appleCA) {
			BIO *payload = BIO_new(BIO_s_mem());
			X509_STORE_add_cert(store, appleCA);

			if (payload) {
				verifyReturnValue = PKCS7_verify(p7, NULL, store, NULL, payload, 0);
				BIO_free(payload);
			}

			X509_free(appleCA);
		}
		X509_STORE_free(store);
	}
	EVP_cleanup();

	if (verifyReturnValue != 1) {
		PKCS7_free(p7);
		return nil;
	}

	ASN1_OCTET_STRING *octets = p7->d.sign->contents->d.data;
	const unsigned char *p = octets->data;
	const unsigned char *end = p + octets->length;

	int type = 0;
	int xclass = 0;
	long length = 0;

	ASN1_get_object(&p, &length, &type, &xclass, end - p);
	if (type != V_ASN1_SET) {
		PKCS7_free(p7);
		return nil;
	}

	NSMutableDictionary *info = [NSMutableDictionary dictionary];

	while (p < end) {
		ASN1_get_object(&p, &length, &type, &xclass, end - p);
		if (type != V_ASN1_SEQUENCE) {
			break;
        }

		const unsigned char *seq_end = p + length;

		int attr_type = 0;
		int attr_version = 0;

		// Attribute type
		ASN1_get_object(&p, &length, &type, &xclass, seq_end - p);
		if (type == V_ASN1_INTEGER && length == 1) {
			attr_type = p[0];
		}
		p += length;

		// Attribute version
		ASN1_get_object(&p, &length, &type, &xclass, seq_end - p);
		if (type == V_ASN1_INTEGER && length == 1) {
			attr_version = p[0];
			attr_version = attr_version;
		}
		p += length;

		// Only parse attributes we're interested in
		if (attr_type > ATTR_START && attr_type < ATTR_END) {
			NSString *key = nil;

			ASN1_get_object(&p, &length, &type, &xclass, seq_end - p);
			if (type == V_ASN1_OCTET_STRING) {
                NSData *data = [NSData dataWithBytes:p length:(NSUInteger)length];
                
				// Bytes
				if (attr_type == BUNDLE_ID || attr_type == OPAQUE_VALUE || attr_type == HASH) {
					switch (attr_type) {
						case BUNDLE_ID:
							// This is included for hash generation
							key = kReceiptBundleIdentifierData;
							break;
						case OPAQUE_VALUE:
							key = kReceiptOpaqueValue;
							break;
						case HASH:
							key = kReceiptHash;
							break;
					}
					if (key) {
                        [info setObject:data forKey:key];
                    }
				}

				// Strings
				if (attr_type == BUNDLE_ID || attr_type == VERSION) {
					int str_type = 0;
					long str_length = 0;
					const unsigned char *str_p = p;
					ASN1_get_object(&str_p, &str_length, &str_type, &xclass, seq_end - str_p);
					if (str_type == V_ASN1_UTF8STRING) {
						switch (attr_type) {
							case BUNDLE_ID:
								key = kReceiptBundleIdentifier;
								break;
							case VERSION:
								key = kReceiptVersion;
								break;
						}
                        
						if (key) {                        
                            NSString *string = [[NSString alloc] initWithBytes:str_p
																		length:(NSUInteger)str_length
                                                                      encoding:NSUTF8StringEncoding];
                            [info setObject:string forKey:key];
                            [string release];
						}
					}
				}
			}
			p += length;
		}

		// Skip any remaining fields in this SEQUENCE
		while (p < seq_end) {
			ASN1_get_object(&p, &length, &type, &xclass, seq_end - p);
			p += length;
		}
	}

	PKCS7_free(p7);

	return info;
}


CFDataRef copy_mac_address()
{
	kern_return_t			 kernResult;
	mach_port_t			   master_port;
	CFMutableDictionaryRef	matchingDict;
	io_iterator_t			 iterator;
	io_object_t			   service;
	CFDataRef				 macAddress = nil;

	kernResult = IOMasterPort(MACH_PORT_NULL, &master_port);
	if (kernResult != KERN_SUCCESS) {
		printf("IOMasterPort returned %d\n", kernResult);
		return nil;
	}

	matchingDict = IOBSDNameMatching(master_port, 0, "en0");
	if (!matchingDict) {
		printf("IOBSDNameMatching returned empty dictionary\n");
		return nil;
	}

	kernResult = IOServiceGetMatchingServices(master_port, matchingDict, &iterator);
	if (kernResult != KERN_SUCCESS) {
		printf("IOServiceGetMatchingServices returned %d\n", kernResult);
		return nil;
	}

	while ((service = IOIteratorNext(iterator)) != 0) {
		io_object_t parentService;

		kernResult = IORegistryEntryGetParentEntry(service, kIOServicePlane, &parentService);
		if (kernResult == KERN_SUCCESS) {
			VRCFRelease(macAddress);
			macAddress = IORegistryEntryCreateCFProperty(parentService, CFSTR("IOMACAddress"), kCFAllocatorDefault, 0);
			IOObjectRelease(parentService);
		} else {
			printf("IORegistryEntryGetParentEntry returned %d\n", kernResult);
		}

		IOObjectRelease(service);
	}

	return macAddress;
}

extern const NSString *gAppBundleVersion;
extern const NSString *gAppBundleIdentifier;

BOOL validateReceiptAtURL(NSURL *url)
{
	NSCAssert([gAppBundleVersion isEqualToString:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]],
			 @"Inconsistent CFBundleShortVersionString");
	NSCAssert([gAppBundleIdentifier isEqualToString:[[NSBundle mainBundle] bundleIdentifier]],
			 @"Inconsistent Bundle Identifier!");

	NSDictionary *receipt = dictionaryWithAppStoreReceipt(url);
	if (!receipt) {
		return NO;
    }

	NSData *guidData = (NSData *)copy_mac_address();

	if ([NSGarbageCollector defaultCollector]) {
		[[NSGarbageCollector defaultCollector] enableCollectorForPointer:guidData];
	} else {
		[guidData autorelease];
    }

	if (!guidData) {
		return NO;
    }

	NSMutableData *input = [NSMutableData data];
	[input appendData:guidData];
	[input appendData:[receipt objectForKey:kReceiptOpaqueValue]];
	[input appendData:[receipt objectForKey:kReceiptBundleIdentifierData]];

	NSMutableData *hash = [NSMutableData dataWithLength:SHA_DIGEST_LENGTH];
	SHA1([input bytes], [input length], [hash mutableBytes]);

	if ([gAppBundleIdentifier isEqualToString:[receipt objectForKey:kReceiptBundleIdentifier]] &&
		 [gAppBundleVersion isEqualToString:[receipt objectForKey:kReceiptVersion]] &&
		 [hash isEqualToData:[receipt objectForKey:kReceiptHash]])
	{
		return YES;
	}

	return NO;
}


