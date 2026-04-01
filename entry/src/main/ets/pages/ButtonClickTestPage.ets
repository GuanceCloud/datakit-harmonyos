import promptAction from '@ohos.promptAction';
import { NetworkImage } from '../components/NetworkImage';
import { TestPageHeader } from '../components/TestPageHeader';
import { TestPageTheme } from '../constants/TestPageTheme';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = "ButtonClickTestPage";

/**
 * Component Click Test Page
 * Tests automatic action tracking via FTActionTracker for Button, Checkbox, Radio, and Toggle
 * Click components below to verify that actions are automatically tracked
 */
@Entry
@Component
export struct ButtonClickTestPage {
  @State message: string = 'Component Click Auto-Tracking Test';
  @State clickCount: number = 0;
  @State testResults: string = 'Click components below to test automatic action tracking.\nEach component has a unique ID and should be tracked automatically.\n';
  @State trackedActions: string[] = [];
  
  // Component states
  @State isCheckbox1Checked: boolean = false;
  @State isCheckbox2Checked: boolean = false;
  @State isToggle1Checked: boolean = false;
  @State isToggle2Checked: boolean = false;
  @State radioValue: string = 'option1';

  aboutToAppear() {
    DemoLogger.i(TAG, "ButtonClickTestPage aboutToAppear");
    this.testResults = 'Component Click Auto-Tracking Test Page\n';
    this.testResults += '========================================\n';
    this.testResults += 'Supported Components: Button, Checkbox, Radio, Toggle, Text, Image\n';
    this.testResults += '========================================\n';
    this.testResults += 'Instructions:\n';
    this.testResults += '1. Click any component below (Button, Checkbox, Radio, Toggle)\n';
    this.testResults += '2. Each click should be automatically tracked by FTActionTracker\n';
    this.testResults += '3. Action name format: ComponentType/{componentId}\n';
    this.testResults += '   - Button: Button/{id} or Button/\n';
    this.testResults += '   - Checkbox: Checkbox/{id} or Checkbox/\n';
    this.testResults += '   - Radio: Radio/{id} or Radio/\n';
    this.testResults += '   - Toggle: Toggle/{id} or Toggle/\n';
    this.testResults += '   - Text: Text/{id} or Text/ (TextView onClick)\n';
    this.testResults += '   - Image: Image/{id} or Image/ (ImageView onClick)\n';
    this.testResults += '4. Check logs for "[ACTION-TRACK]" to see tracking details\n';
    this.testResults += '5. Action data will be uploaded to server as RUM action data\n';
    this.testResults += '\nNote: Make sure FTSDK.initializeUIFeatures() was called in EntryAbility\n';
    this.testResults += '========================================\n\n';
  }

  /**
   * Handle component click and record it
   */
  private handleComponentClick(componentType: string, componentId: string, description: string) {
    this.clickCount++;
    const timestamp = new Date().toLocaleTimeString();
    const actionInfo = `[${timestamp}] Clicked: ${description} (Type: ${componentType}, ID: ${componentId || 'none'})\n`;
    this.trackedActions.push(actionInfo);
    this.testResults += `✅ ${actionInfo}`;
    
    // Expected action name format: ComponentType/{componentId}
    const expectedActionName = componentId ? `${componentType}/${componentId}` : `${componentType}/`;
    this.testResults += `   Expected action name: ${expectedActionName}\n`;
    this.testResults += `   Component type: ${componentType}\n`;
    this.testResults += `   Action type: click\n`;
    this.testResults += `   Should be tracked automatically by FTActionTracker\n\n`;
    
    DemoLogger.i(TAG, `${componentType} clicked: ${description}, ID: ${componentId || '(no id)'}, Expected action: ${expectedActionName}`);
    promptAction.showToast({
      message: `Clicked: ${description}`,
      duration: 1500
    });
  }

  /**
   * Handle button click - convenience method
   */
  private handleButtonClick(buttonId: string, description: string) {
    this.handleComponentClick('Button', buttonId, description);
  }

  /**
   * Handle checkbox change
   */
  private handleCheckboxChange(value: boolean, checkboxId: string, description: string) {
    // Update state based on checkbox ID
    if (checkboxId === 'test-checkbox-1') {
      this.isCheckbox1Checked = value;
    } else if (checkboxId === 'test-checkbox-2') {
      this.isCheckbox2Checked = value;
    }
    this.handleComponentClick('Checkbox', checkboxId, `${description} (${value ? 'Checked' : 'Unchecked'})`);
  }

  /**
   * Handle radio change
   */
  private handleRadioChange(value: string, radioId: string, description: string) {
    this.radioValue = value;
    this.handleComponentClick('Radio', radioId, `${description} (Selected)`);
  }

  /**
   * Handle toggle change
   */
  private handleToggleChange(value: boolean, toggleId: string, description: string) {
    // Update state based on toggle ID
    if (toggleId === 'test-toggle-1') {
      this.isToggle1Checked = value;
    } else if (toggleId === 'test-toggle-2') {
      this.isToggle2Checked = value;
    }
    this.handleComponentClick('Toggle', toggleId, `${description} (${value ? 'On' : 'Off'})`);
  }

  /**
   * Clear test results
   */
  private clearResults() {
    this.testResults = 'Test results cleared.\n';
    this.trackedActions = [];
    this.clickCount = 0;
    promptAction.showToast({
      message: "Results cleared",
      duration: 1500
    });
  }

  /**
   * Show statistics
   */
  private showStats() {
    this.testResults += `\n📊 Statistics:\n`;
    this.testResults += `Total clicks: ${this.clickCount}\n`;
    this.testResults += `Tracked actions: ${this.trackedActions.length}\n`;
    this.testResults += `\n✅ All clicks should be automatically tracked as actions\n`;
    this.testResults += `🔍 Check SDK logs for action tracking details\n`;
    this.testResults += `📤 Action data should be uploaded to server\n\n`;
    
    promptAction.showToast({
      message: `Total clicks: ${this.clickCount}`,
      duration: 2000
    });
  }

  build() {
    Column() {
      TestPageHeader({
        title: this.message
      })

    Scroll() {
      Column({ space: 12 }) {

        // Statistics Row
        Row() {
          Text(`Total Clicks: ${this.clickCount}`)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ bottom: 20 })

        // Instructions
        Text('Test Buttons (Click to verify auto-tracking):')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .width('100%')
          .margin({ bottom: 10 })

        Divider()
          .margin({ top: 10, bottom: 10 })

        // Test Button 1
        Button('Test Button 1 - Basic Click')
          .id('test-button-1')
          .customProperty('test-button-1', 'Test Button 1 - Basic Click')
          .width('100%')
          .height(56)
          .backgroundColor('#007DFF')
          .fontColor(Color.White)
          .fontSize(16)
          .onClick(() => {
            this.handleButtonClick('test-button-1', 'Test Button 1 - Basic Click');
          })

        // Test Button 2
        Button('Test Button 2 - Different ID')
          .id('test-button-2')
          .customProperty('test-button-2', 'Test Button 2 - Different ID')
          .width('100%')
          .height(56)
          .backgroundColor('#4CAF50')
          .fontColor(Color.White)
          .fontSize(16)
          .onClick(() => {
            this.handleButtonClick('test-button-2', 'Test Button 2 - Different ID');
          })

        // Test Button 3
        Button('Test Button 3 - Quick Click')
          .id('test-button-3')
          .customProperty('test-button-3', 'Test Button 3 - Quick Click')
          .width('100%')
          .height(56)
          .backgroundColor('#FF9800')
          .fontColor(Color.White)
          .fontSize(16)
          .onClick(() => {
            this.handleButtonClick('test-button-3', 'Test Button 3 - Quick Click');
          })

        // Test Button 4
        Button('Test Button 4 - Action Tracking')
          .id('test-button-action-tracking')
          .customProperty('test-button-action-tracking', 'Test Button 4 - Action Tracking')
          .width('100%')
          .height(56)
          .backgroundColor('#9C27B0')
          .fontColor(Color.White)
          .fontSize(16)
          .onClick(() => {
            this.handleButtonClick('test-button-action-tracking', 'Test Button 4 - Action Tracking');
          })

        // Test Button 5
        Button('Test Button 5 - Submit')
          .id('submit-button')
          .customProperty('submit-button', 'Test Button 5 - Submit')
          .width('100%')
          .height(56)
          .backgroundColor('#F44336')
          .fontColor(Color.White)
          .fontSize(16)
          .onClick(() => {
            this.handleButtonClick('submit-button', 'Test Button 5 - Submit');
          })

        // Test Button 6
        Button('Test Button 6 - Cancel')
          .id('cancel-button')
          .customProperty('cancel-button', 'Test Button 6 - Cancel')
          .width('100%')
          .height(56)
          .backgroundColor('#607D8B')
          .fontColor(Color.White)
          .fontSize(16)
          .onClick(() => {
            this.handleButtonClick('cancel-button', 'Test Button 6 - Cancel');
          })

        // Test Button 7 (No ID - should still be tracked)
        Button('Test Button 7 - No ID')
          .width('100%')
          .height(56)
          .backgroundColor('#795548')
          .fontColor(Color.White)
          .fontSize(16)
          .onClick(() => {
            this.handleButtonClick('', 'Test Button 7 - No ID');
          })
          .customProperty('action_name', 'Test Button 7 - No ID')

        // Test Button 8
        Button('Test Button 8 - Long Description Button')
          .id('long-description-button')
          .width('100%')
          .height(56)
          .backgroundColor('#00BCD4')
          .fontColor(Color.White)
          .fontSize(16)
          .onClick(() => {
            this.handleButtonClick('long-description-button', 'Test Button 8 - Long Description Button');
          })

        Divider()
          .margin({ top: 20, bottom: 10 })

        // Checkbox Tests
        Text('Test Checkboxes (Click to verify auto-tracking):')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .width('100%')
          .margin({ bottom: 10 })

        Row() {
          Checkbox({ name: 'test-checkbox-1', group: 'checkbox-group-1' })
            .select(this.isCheckbox1Checked)
            .id('test-checkbox-1')
            .customProperty('test-checkbox-1', 'Test Checkbox 1 (Click to toggle)')
            .onChange((value: boolean) => {
              this.handleCheckboxChange(value, 'test-checkbox-1', 'Test Checkbox 1');
            })
          Text('Test Checkbox 1 - Basic Checkbox')
            .margin({ left: 12 })
            .fontSize(16)
        }
        .width('100%')
        .height(56)
        .padding({ left: 16, right: 16 })
        .backgroundColor('#FFFFFF')
        .borderRadius(8)
        .margin({ bottom: 8 })

        Row() {
          Checkbox({ name: 'test-checkbox-2', group: 'checkbox-group-2' })
            .select(this.isCheckbox2Checked)
            .id('test-checkbox-2')
            .customProperty('test-checkbox-2', 'Test Checkbox 2 (Click to toggle)')
            .onChange((value: boolean) => {
              this.handleCheckboxChange(value, 'test-checkbox-2', 'Test Checkbox 2');
            })
          Text('Test Checkbox 2 - Another Checkbox')
            .margin({ left: 12 })
            .fontSize(16)
        }
        .width('100%')
        .height(56)
        .padding({ left: 16, right: 16 })
        .backgroundColor('#FFFFFF')
        .borderRadius(8)

        Divider()
          .margin({ top: 20, bottom: 10 })

        // Radio Tests
        Text('Test Radio Buttons (Click to verify auto-tracking):')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .width('100%')
          .margin({ bottom: 10 })

        Row() {
          Radio({ value: 'option1', group: 'radio-test-group' })
            .checked(this.radioValue === 'option1')
            .id('test-radio-1')
            .customProperty('test-radio-1', 'Radio Option 1 (Click to select)')
            .onChange((isChecked: boolean) => {
              if (isChecked) {
                this.handleRadioChange('option1', 'test-radio-1', 'Radio Option 1');
              }
            })
          Text('Radio Option 1 - First Option')
            .margin({ left: 12 })
            .fontSize(16)
        }
        .width('100%')
        .height(56)
        .padding({ left: 16, right: 16 })
        .backgroundColor('#FFFFFF')
        .borderRadius(8)
        .margin({ bottom: 8 })

        Row() {
          Radio({ value: 'option2', group: 'radio-test-group' })
            .checked(this.radioValue === 'option2')
            .id('test-radio-2')
            .customProperty('test-radio-2', 'Radio Option 2 (Click to select)')
            .onChange((isChecked: boolean) => {
              if (isChecked) {
                this.handleRadioChange('option2', 'test-radio-2', 'Radio Option 2');
              }
            })
          Text('Radio Option 2 - Second Option')
            .margin({ left: 12 })
            .fontSize(16)
        }
        .width('100%')
        .height(56)
        .padding({ left: 16, right: 16 })
        .backgroundColor('#FFFFFF')
        .borderRadius(8)
        .margin({ bottom: 8 })

        Row() {
          Radio({ value: 'option3', group: 'radio-test-group' })
            .checked(this.radioValue === 'option3')
            .id('test-radio-3')
            .customProperty('test-radio-3', 'Radio Option 3 (Click to select)')
            .onChange((isChecked: boolean) => {
              if (isChecked) {
                this.handleRadioChange('option3', 'test-radio-3', 'Radio Option 3');
              }
            })
          Text('Radio Option 3 - Third Option')
            .margin({ left: 12 })
            .fontSize(16)
        }
        .width('100%')
        .height(56)
        .padding({ left: 16, right: 16 })
        .backgroundColor('#FFFFFF')
        .borderRadius(8)

        Divider()
          .margin({ top: 20, bottom: 10 })

        // Toggle Tests
        Text('Test Toggles (Click to verify auto-tracking):')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .width('100%')
          .margin({ bottom: 10 })

        Row() {
          Toggle({ type: 0, isOn: this.isToggle1Checked }) // 0 = Switch type
            .id('test-toggle-1')
            .customProperty('test-toggle-1', 'Test Toggle 1 (Click to toggle)')
            .onChange((isOn: boolean) => {
              this.handleToggleChange(isOn, 'test-toggle-1', 'Test Toggle 1');
            })
          Text('Test Toggle 1 - Switch Style')
            .margin({ left: 12 })
            .fontSize(16)
        }
        .width('100%')
        .height(56)
        .padding({ left: 16, right: 16 })
        .backgroundColor('#FFFFFF')
        .borderRadius(8)
        .margin({ bottom: 8 })

        Row() {
          Toggle({ type: 1, isOn: this.isToggle2Checked }) // 1 = Checkbox type
            .id('test-toggle-2')
            .customProperty('test-toggle-2', 'Test Toggle 2 (Click to toggle)')
            .onChange((isOn: boolean) => {
              this.handleToggleChange(isOn, 'test-toggle-2', 'Test Toggle 2');
            })
          Text('Test Toggle 2 - Checkbox Style')
            .margin({ left: 12 })
            .fontSize(16)
        }
        .width('100%')
        .height(56)
        .padding({ left: 16, right: 16 })
        .backgroundColor('#FFFFFF')
        .borderRadius(8)

        Divider()
          .margin({ top: 20, bottom: 10 })

        // Text (TextView) Tests
        Text('Test Text Components (Click to verify auto-tracking):')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .width('100%')
          .margin({ bottom: 10 })

        // Test Text 1 - Basic Text with onClick
        Text('Test Text 1 - Clickable Text (Basic)')
          .id('test-text-1')
          .customProperty('test-text-1', 'Test Text 1 - Clickable Text (Basic)')
          .fontSize(16)
          .fontColor('#007DFF')
          .width('100%')
          .height(56)
          .textAlign(TextAlign.Center)
          .backgroundColor('#E3F2FD')
          .borderRadius(8)
          .margin({ bottom: 8 })
          .onClick(() => {
            this.handleComponentClick('Text', 'test-text-1', 'Test Text 1 - Clickable Text (Basic)');
          })

        // Test Text 2 - Text with different ID
        Text('Test Text 2 - Another Clickable Text')
          .id('test-text-2')
          .customProperty('test-text-2', 'Test Text 2 - Another Clickable Text')
          .fontSize(16)
          .fontColor('#4CAF50')
          .width('100%')
          .height(56)
          .textAlign(TextAlign.Center)
          .backgroundColor('#E8F5E9')
          .borderRadius(8)
          .margin({ bottom: 8 })
          .onClick(() => {
            this.handleComponentClick('Text', 'test-text-2', 'Test Text 2 - Another Clickable Text');
          })

        // Test Text 3 - Text with custom action name
        Text('Test Text 3 - Custom Action Name')
          .id('test-text-3')
          .customProperty('action_name', 'Custom Text Action Name')
          .fontSize(16)
          .fontColor('#FF9800')
          .width('100%')
          .height(56)
          .textAlign(TextAlign.Center)
          .backgroundColor('#FFF3E0')
          .borderRadius(8)
          .margin({ bottom: 8 })
          .onClick(() => {
            this.handleComponentClick('Text', 'test-text-3', 'Test Text 3 - Custom Action Name');
          })

        // Test Text 4 - Text without ID (should use customProperty action_name)
        Text('Test Text 4 - No ID Text')
          .customProperty('action_name', 'Test Text 4 - No ID Text')
          .fontSize(16)
          .fontColor('#9C27B0')
          .width('100%')
          .height(56)
          .textAlign(TextAlign.Center)
          .backgroundColor('#F3E5F5')
          .borderRadius(8)
          .margin({ bottom: 8 })
          .onClick(() => {
            this.handleComponentClick('Text', '', 'Test Text 4 - No ID Text');
          })

        Divider()
          .margin({ top: 20, bottom: 10 })

        // Image (ImageView) Tests
        Text('Test Image Components (Click to verify auto-tracking):')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .width('100%')
          .margin({ bottom: 10 })

        // Test Image 1 - Basic Image with onClick
        Row() {
          NetworkImage({ src: 'https://img1.baidu.com/it/u=4111161705,1085912078&fm=253&fmt=auto&app=138&f=JPEG?w=805&h=800' })
            .id('test-image-1')
            .customProperty('__component_type__', 'Image')
            .customProperty('test-image-1', 'Test Image 1 - Basic Image')
            .width(48)
            .height(48)
            .borderRadius(8)
            .backgroundColor('#007DFF')
            .onClick(() => {
              this.handleComponentClick('Image', 'test-image-1', 'Test Image 1 - Basic Image');
            })
          Text('Test Image 1 - Basic Clickable Image')
            .margin({ left: 12 })
            .fontSize(16)
        }
        .width('100%')
        .height(56)
        .padding({ left: 16, right: 16 })
        .backgroundColor('#FFFFFF')
        .borderRadius(8)
        .margin({ bottom: 8 })

        // Test Image 2 - Image with different ID
        Row() {
          NetworkImage({ src: 'https://img1.baidu.com/it/u=4111161705,1085912078&fm=253&fmt=auto&app=138&f=JPEG?w=805&h=800' })
            .id('test-image-2')
            .customProperty('__component_type__', 'Image')
            .customProperty('test-image-2', 'Test Image 2 - Another Image')
            .width(48)
            .height(48)
            .borderRadius(8)
            .backgroundColor('#4CAF50')
            .onClick(() => {
              this.handleComponentClick('Image', 'test-image-2', 'Test Image 2 - Another Image');
            })
          Text('Test Image 2 - Another Clickable Image')
            .margin({ left: 12 })
            .fontSize(16)
        }
        .width('100%')
        .height(56)
        .padding({ left: 16, right: 16 })
        .backgroundColor('#FFFFFF')
        .borderRadius(8)
        .margin({ bottom: 8 })

        // Test Image 3 - Image with custom action name
        Row() {
          NetworkImage({ src: 'https://img1.baidu.com/it/u=4111161705,1085912078&fm=253&fmt=auto&app=138&f=JPEG?w=805&h=800' })
            .id('test-image-3')
            .customProperty('__component_type__', 'Image')
            .customProperty('action_name', 'Custom Image Action Name')
            .width(48)
            .height(48)
            .borderRadius(8)
            .backgroundColor('#FF9800')
            .onClick(() => {
              this.handleComponentClick('Image', 'test-image-3', 'Test Image 3 - Custom Action Name');
            })
          Text('Test Image 3 - Custom Action Name')
            .margin({ left: 12 })
            .fontSize(16)
        }
        .width('100%')
        .height(56)
        .padding({ left: 16, right: 16 })
        .backgroundColor('#FFFFFF')
        .borderRadius(8)
        .margin({ bottom: 8 })

        // Test Image 4 - Image without ID
        Row() {
          NetworkImage({ src: 'https://img1.baidu.com/it/u=4111161705,1085912078&fm=253&fmt=auto&app=138&f=JPEG?w=805&h=800' })
            .customProperty('__component_type__', 'Image')
            .customProperty('action_name', 'Test Image 4 - No ID Image')
            .width(48)
            .height(48)
            .borderRadius(8)
            .backgroundColor('#9C27B0')
            .onClick(() => {
              this.handleComponentClick('Image', '', 'Test Image 4 - No ID Image');
            })
          Text('Test Image 4 - No ID Image')
            .margin({ left: 12 })
            .fontSize(16)
        }
        .width('100%')
        .height(56)
        .padding({ left: 16, right: 16 })
        .backgroundColor('#FFFFFF')
        .borderRadius(8)
        .margin({ bottom: 8 })

        Divider()
          .margin({ top: 20, bottom: 10 })

        // Action Buttons Row
        Row({ space: 10 }) {
          Button('Show Statistics')
            .layoutWeight(1)
            .height(50)
            .backgroundColor('#4CAF50')
            .fontColor(Color.White)
            .onClick(() => this.showStats())

        }
        .width('100%')
        .margin({ top: 20, bottom: 10 })
        
        // Info Section
        Column({ space: 8 }) {
          Text('ℹ️ Important Information:')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .width('100%')
            .margin({ bottom: 5 })

          Text('• Each component click should automatically trigger FTActionTracker')
            .fontSize(12)
            .width('100%')

          Text('• Supported components: Button, Checkbox, Radio, Toggle, Text, Image')
            .fontSize(12)
            .width('100%')

          Text('• Action name format: ComponentType/{id} or ComponentType/ (if no ID)')
            .fontSize(12)
            .width('100%')

          Text('• Check logs for "[ACTION-TRACK]" to see tracking details')
            .fontSize(12)
            .width('100%')

          Text('• Action data will be uploaded to server as RUM action data')
            .fontSize(12)
            .width('100%')

          Text('• Make sure FTSDK.initializeUIFeatures() was called')
            .fontSize(12)
            .width('100%')
        }
        .width('100%')
        .padding(12)
        .backgroundColor('#E3F2FD')
        .borderRadius(8)
        .margin({ bottom: 20 })
      }
      .width('100%')
      .padding(20)
    }
    .width('100%')
    .layoutWeight(1)
    .backgroundColor('#F5F5F5')
    .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TestPageTheme.PAGE_BACKGROUND)
  }
}
